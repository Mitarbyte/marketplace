# user-onboarding-Installer (Windows) — kopiert den Skill nach ~\.claude\skills\.
# Laedt in Desktop-App, Web und Terminal. Kein GitHub-Login noetig.
#   irm https://raw.githubusercontent.com/Mitarbyte/marketplace/main/install.ps1 | iex
$ErrorActionPreference = 'Stop'
$zipUrl   = 'https://github.com/Mitarbyte/marketplace/archive/refs/heads/main.zip'
$skillSub = 'marketplace-main\plugins\user-onboarding\skills\user-onboarding'
$dest = Join-Path $env:USERPROFILE '.claude\skills\user-onboarding'
$tmp  = Join-Path $env:TEMP ('kios-' + [guid]::NewGuid().ToString())

New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  Write-Host '> Lade user-onboarding-Skill ...'
  $zip = Join-Path $tmp 'm.zip'
  Invoke-WebRequest -Uri $zipUrl -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $src = Join-Path $tmp $skillSub
  if (-not (Test-Path (Join-Path $src 'SKILL.md'))) { throw 'Skill im Archiv nicht gefunden.' }
  if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
  New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
  Copy-Item -Recurse -Force $src $dest
  Write-Host "OK - installiert nach $dest"
  Write-Host "  Jetzt Claude Code starten (Desktop-App oder 'claude') und /user-onboarding aufrufen."
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
