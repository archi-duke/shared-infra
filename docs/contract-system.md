# shared-infra 계약 전파 시스템

C(shared-infra)의 연결 계약 변경을 감지해 소비자(GoJIRA·RAGaaS)에게 전파한다.
정책: **비파괴 = 즉시 반영(자동), 파괴적 = 승인 게이트(Duke PR 승인)**.

## 동작 흐름

```
C: compose/init/env merge to main
   └─ contract-guard (Actions)
        ├─ 계약 재추출 → 직전 스냅샷과 구조적 diff → 버전 bump
        ├─ .contract/contract.json 커밋 (published)
        └─ 영향받는 소비자에게만 repository_dispatch (push)
                    │
   A·B: infra-contract-listener (Actions, dispatch 수신)
        ├─ C 최신 계약 fetch → 로컬 lock 과 비교(자기 의존성만)
        ├─ additive → lock 자동 갱신 + CHANGELOG 커밋   (즉시 반영)
        └─ breaking → 영향 스캔 + PR(needs-approval) 생성 후 대기  (Duke 머지로 승인)

   A·B: SessionStart 훅(catch-up) → 세션 시작 시 드리프트를 컨텍스트로 주입
```

"누가 변경을 유발했는가"는 추적하지 않는다 — A발이든 B발이든 변경은 C 커밋으로 착지하므로,
감지 지점을 C 한 곳에 두면 양방향이 대칭으로 처리된다.

## 계약 표면(무엇이 변경 대상인가)

`docker-compose.yml` + `init/` + `.env.example` 에서 추출:
네트워크명, 서비스 컨테이너명(DNS), 포트(host/internal), 이미지 major,
Mongo db/앱계정 규약, env 계약 키.

**breaking 판정**: 네트워크 rename · 서비스 제거 · 컨테이너명 변경 · 포트 제거/변경 ·
이미지 major 변경 · env 키 제거/rename · Mongo db/계정 제거·rename.
**additive**: 신규 서비스/포트/env 추가, 동일 major 내 minor·patch 갱신.

## 설치

### C (shared-infra)
```
tools/infra_contract.py
.contract/contract.json                 # 초기 스냅샷(1.0.0) 포함됨
.github/workflows/contract-guard.yml
```
- Settings → Secrets → **`DISPATCH_TOKEN`** 등록: A·B repo 에 dispatch 를 보낼 PAT(repo scope).
  (Fine-grained PAT 라면 GoJIRA·RAGaaS 두 repo 의 *Contents: read, Metadata: read* + *repository_dispatch* 권한.)

### A(GoJIRA) · B(RAGaaS) — consumer-template 를 각 repo 루트에 복사
```
tools/infra_contract.py
.infra-deps.yml                         # RAGaaS 기본. GoJIRA 는 .infra-deps.gojira.yml 를 .infra-deps.yml 로 사용
.contract/contract.lock.json            # 초기 lock(=현재 published)
.github/workflows/infra-contract-listener.yml
.claude/settings.json                   # SessionStart 훅 등록
.claude/hooks/check_upstream.sh
.claude/hooks/scan_impact.sh
```
- 추가 secret 불필요(리스너는 기본 `GITHUB_TOKEN` 으로 자기 repo PR 생성).
- 리스너 catch-up 스케줄(cron)은 기본 1시간. 불필요하면 제거 가능.

## 엔진 CLI (양쪽 공용)

```
python3 tools/infra_contract.py extract <repo>                  # 계약 JSON
python3 tools/infra_contract.py compare <old.json> <new> \      # diff+분류+영향
        [--consumer NAME] [--json]
#   exit: 0=무변경  10=additive만  20=breaking 포함  → CI/훅 분기용
```

## 알려진 한계

- `stain/jena-fuseki:latest`, minio `RELEASE.…` 처럼 **고정 태그가 아닌 이미지**는
  태그 문자열이 그대로면 실제 갱신이 diff 에 안 잡힌다. 버전 태그로 pin 하면 diffable 해진다.
  (C 의 README TODO 와 동일 사안.)
- 영향 스캔은 리터럴 문자열 grep 기반. 간접 참조까지 필요하면 `scan_impact.sh` 안의
  grep 자리를 `claude -p "..."` headless 호출로 교체하면 의미 분석으로 승급된다.

## 확장: 에이전트끼리 협의 자동화

승인은 사람(Duke)이 하되, PR 본문의 영향 스캔을 `claude -p` 로 강화하면
"우리 3곳이 깨진다 / 마이그레이션 diff 초안" 까지 자동 첨부되어 승인 판단이 쉬워진다.
이때가 원래 목표였던 "C 계약을 매개로 한 A(변경자) ↔ B(검증자)" 협업이 실현되는 지점.
