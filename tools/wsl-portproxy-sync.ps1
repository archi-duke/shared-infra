# Sync netsh portproxy rules (0.0.0.0:PORT -> current WSL IP:PORT) for shared-infra.
# WSL IP changes after reboot / `wsl --shutdown`; LAN clients (Mac) then lose access.
# Registered as scheduled task "shared-infra-portproxy-sync" (at logon, highest privileges).
# Manual run: elevated PowerShell -> powershell -ExecutionPolicy Bypass -File tools\wsl-portproxy-sync.ps1
# See docs/wsl-portproxy.md.

param(
  [string]$Distro = 'Ubuntu-24.04',
  [int[]]$Ports = @(44370, 44372, 44375, 44380, 44381, 44385, 44386, 44390, 44395, 44396)
)

$logDir = Join-Path $env:LOCALAPPDATA 'shared-infra'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir 'portproxy-sync.log'
function Write-Log($msg) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Out-File $log -Append -Encoding utf8 }

# Wait for the WSL VM (keepalive task starts it at logon) and read its eth0 IP.
$ip = $null
for ($i = 0; $i -lt 36 -and -not $ip; $i++) {
  $out = (& wsl.exe -d $Distro -- hostname -I) 2>$null
  $first = (("$out").Trim() -split '\s+')[0]
  if ($first -match '^\d+\.\d+\.\d+\.\d+$') { $ip = $first } else { Start-Sleep -Seconds 5 }
}
if (-not $ip) { Write-Log "ERROR: could not get WSL IP for $Distro"; exit 1 }

# Current rules: "0.0.0.0  44370  172.x.x.x  44370"
$current = @{}
foreach ($line in (netsh interface portproxy show v4tov4)) {
  if ($line -match '^\s*0\.0\.0\.0\s+(\d+)\s+(\S+)\s+(\d+)') { $current[[int]$Matches[1]] = $Matches[2] }
}

$changed = @()
foreach ($p in $Ports) {
  if ($current[$p] -ne $ip) {
    netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=$p 2>$null | Out-Null
    netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$p connectaddress=$ip connectport=$p | Out-Null
    $changed += $p
  }
}
if ($changed) { Write-Log "WSL IP $ip - updated ports: $($changed -join ',')" } else { Write-Log "WSL IP $ip - all rules already current" }
