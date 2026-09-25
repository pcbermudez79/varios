# Install Local Hardware Agent as an autostart on Windows.
# Two options: (1) NSSM service (recommended, requires NSSM installed)
#              (2) Registry Run key (per-user, no admin required)
# Usage:
#   .\install-windows.ps1 -ExePath "C:\Program Files\LocalHardwareAgent\local-hardware-agent-win.exe" [-AsService]

param(
  [Parameter(Mandatory=$true)][string]$ExePath,
  [switch]$AsService,
  [string]$ServiceName = "LocalHardwareAgent"
)

if (-not (Test-Path $ExePath)) { throw "Executable not found: $ExePath" }

if ($AsService) {
  $nssm = Get-Command nssm.exe -ErrorAction SilentlyContinue
  if (-not $nssm) { throw "NSSM not found. Install from https://nssm.cc/download and add to PATH." }
  & nssm install $ServiceName $ExePath
  & nssm set     $ServiceName Start SERVICE_AUTO_START
  & nssm set     $ServiceName AppStdout "$env:ProgramData\LocalHardwareAgent\agent.out.log"
  & nssm set     $ServiceName AppStderr "$env:ProgramData\LocalHardwareAgent\agent.err.log"
  New-Item -ItemType Directory -Force -Path "$env:ProgramData\LocalHardwareAgent" | Out-Null
  & nssm start $ServiceName
  Write-Host "Installed and started $ServiceName."
} else {
  $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
  New-ItemProperty -Path $regPath -Name $ServiceName -Value ('"{0}"' -f $ExePath) -PropertyType String -Force | Out-Null
  Write-Host "Registered $ServiceName in HKCU Run key. Will start on next logon."
  Write-Host "You can start it now with: & '$ExePath'"
}
