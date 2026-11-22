# WSL2 portproxy — LAN 노출 및 절전 재발 방지

## 증상

Mac 등 LAN 클라이언트에서 `192.168.219.108:<port>`(2026-11-22 새 PC 이전 후 IP, 이전 .115) 로 shared-infra 서비스(mongo 등)에
접속하면:

- TCP 핸드셰이크(nc)는 **OPEN** 인데
- 실제 wire(mongo/redis 프로토콜)는 **즉시 close** 됨 (Compass: `connection closed`,
  간헐적으로 `EADDRINUSE 127.0.0.1:<port>`)

Windows 로컬(`docker exec ... ping`)과 docker 내부 네트워크는 정상이라 "서버는 멀쩡"해 보인다.

## 근본 원인

```
[Mac] → 192.168.219.108:PORT (Windows LAN)
      → netsh portproxy: Listen 0.0.0.0:PORT → Connect 127.0.0.1:PORT   ← 문제
      → (원래 WSL2 localhost-forwarding mirror 가 127.0.0.1:PORT 에서 받아 WSL 로 넘겨야 함)
      → WSL 172.x:PORT → docker → 컨테이너
```

과거 수동 생성된 정적 규칙이 connect 대상을 `127.0.0.1` 로 지정해, 죽기 쉬운 WSL2
localhost mirror 에 의존한다. **매일 밤 절전/아침 재개 시 그 mirror 가 사망**하면:

- `0.0.0.0` 리스너가 자신의 `127.0.0.1` 연결을 스스로 받아 무한 자기루프 →
  wire 즉시 붕괴 + 임시포트(TIME_WAIT) 폭증.

이것이 "어제는 됐는데 오늘 안 되는" 이유다. 재부팅이 아니라 **절전/재개**가 트리거다.
(`wsl --shutdown` 재기동으로도 이 WSL 버전(2.7.x)/Win10 조합에서는 mirror 가 안 붙는다.)

> mirrored 네트워킹 모드(`networkingMode=mirrored`)로 portproxy 를 아예 없앨 수 있으나
> **Windows 11 22H2(빌드 22621)+ 전용**이라 이 머신(Windows 10 / 19045)에서는 불가.

## 해결 — connect 대상을 "살아있는 WSL IP" 로 직접 지정

핵심 통찰: **절전/재개는 WSL VM 을 재시작하지 않는다**(keepalive 가 VM 을 살려둠). 따라서
WSL IP 는 절전을 거쳐도 그대로다. 죽는 것은 Windows 쪽 mirror 뿐이다. portproxy 가
`127.0.0.1`(mirror 의존) 대신 **WSL IP 를 직접** 가리키면 mirror 생사와 무관해지고,
connect 대상이 리스너와 다른 주소라 자기루프도 원천 불가능하다.

### 조치 (관리자 PowerShell, 1회)

```powershell
$ip = ((wsl -d Ubuntu-24.04 -- hostname -I) -split '\s+')[0]      # 현재 WSL IP
foreach ($p in 44370,44372,44375,44380,44381,44385,44386,44390,44395,44396) {
  netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$p 2>$null | Out-Null
  netsh interface portproxy add    v4tov4 listenaddress=0.0.0.0 listenport=$p connectaddress=$ip connectport=$p
}
netsh interface portproxy show v4tov4    # 전부 WSL IP(172.x)를 가리키면 정상
```

이 조치 후 **매일의 절전/재개 문제는 완전히 사라진다.**

### 언제 다시 실행해야 하나

WSL VM 이 재시작되어 WSL IP 가 바뀔 때만 — 즉 **재부팅** 또는 **`wsl --shutdown`** 이후.

- **재부팅**: 자동. 예약작업 `shared-infra-portproxy-sync`(로그온 시, 최고 권한)가
  [`tools/wsl-portproxy-sync.ps1`](../tools/wsl-portproxy-sync.ps1) 을 실행해 WSL IP 로 규칙을 맞춘다.
  로그: `%LOCALAPPDATA%\shared-infra\portproxy-sync.log`.
- **`wsl --shutdown` 후**: 자동 아님. keepalive 를 되살린 뒤(아래) 작업을 수동 실행:
  `Start-ScheduledTask -TaskName 'shared-infra-portproxy-sync'` (권한 불필요).

예약작업 등록(관리자 PowerShell, 1회):

```powershell
$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Works\shared-infra\tools\wsl-portproxy-sync.ps1"'
$t = New-ScheduledTaskTrigger -AtLogOn -User "$env:COMPUTERNAME\$env:USERNAME"; $t.Delay = 'PT30S'
$p = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$s = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'shared-infra-portproxy-sync' -Action $a -Trigger $t -Principal $p -Settings $s -Force
```

### 검증 (권한 불필요)

```powershell
# Mac 과 동일한 LAN 경로로 실제 wire 접속
wsl -d Ubuntu-24.04 -- docker run --rm mongo:8.0 mongosh 'mongodb://192.168.219.108:44370' --quiet --eval 'db.runCommand({ping:1})'
```

## 선행 점검 — WSL VM 이 떠 있는가 (keepalive)

portproxy 이전에, **WSL VM 자체가 유휴 셧다운**되면 스택 전체(mongo/redis/…)가 내려가
LAN·로컬 모두 timeout 난다. 이 WSL 버전은 `vmIdleTimeout` 이 무효라, keepalive 세션
(`~/.gojira/wsl-keepalive.vbs` → `wsl ... sleep infinity`)이 VM 을 상시 붙잡아야 한다.

증상이 "일부 포트"가 아니라 "전부 안 닿음"이면 먼저 이걸 의심한다:

```powershell
# keepalive 프로세스 확인 (없으면 VM 이 유휴로 꺼지는 중)
wsl -d Ubuntu-24.04 -- bash -lc "ps -eo cmd | grep 'sleep infinity' | grep -v grep"
# 재가동
Start-ScheduledTask -TaskName 'GoJIRA-WSL-Keepalive'
```

주의: `wsl --shutdown` 을 수동 실행하면 이 keepalive 세션도 함께 죽는다. 로그온 전까지
자동 복구되지 않으므로, 실행했다면 위 `Start-ScheduledTask` 로 즉시 되살릴 것.

## 참고 — 왜 주기 폴링은 안 하나

로그온 시 1회 동기화만 한다. 절전/재개는 WSL IP 를 바꾸지 않으므로 상시 폴링은 과하다.
`wsl --shutdown` 같은 수동 재시작 뒤에만 위 `Start-ScheduledTask` 로 한 번 더 돌리면 된다.
