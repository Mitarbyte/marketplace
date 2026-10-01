# user-onboarding-Installer (Windows) — kopiert den Skill nach ~\.claude\skills\.
# Laedt in Desktop-App, Web und Terminal. Kein GitHub-Login noetig.
#   irm https://raw.githubusercontent.com/Mitarbyte/marketplace/v2-lts/install.ps1 | iex
$ErrorActionPreference = 'Stop'
$zipUrl   = 'https://github.com/Mitarbyte/marketplace/archive/refs/heads/v2-lts.zip'
# Wurzelordner nicht raten: GitHub kuerzt ein fuehrendes v (v2-lts -> marketplace-2-lts)
$skillRel = 'plugins\user-onboarding\skills\user-onboarding'
$dest = Join-Path $env:USERPROFILE '.claude\skills\user-onboarding'
$tmp  = Join-Path $env:TEMP ('kios-' + [guid]::NewGuid().ToString())

New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  Write-Host '> Lade user-onboarding-Skill ...'
  $zip = Join-Path $tmp 'm.zip'
  Invoke-WebRequest -Uri $zipUrl -OutFile $zip
  Expand-Archive -Path $zip -DestinationPath $tmp -Force
  $src = $null
  foreach ($d in (Get-ChildItem -Path $tmp -Directory)) {
    $c = Join-Path $d.FullName $skillRel
    if (Test-Path (Join-Path $c 'SKILL.md')) { $src = $c; break }
  }
  if (-not $src) { throw 'Skill im Archiv nicht gefunden.' }
  if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
  New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
  Copy-Item -Recurse -Force $src $dest
  Write-Host "OK - installiert nach $dest"
  Write-Host "  Jetzt Claude Code starten (Desktop-App oder 'claude') und /user-onboarding aufrufen."
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
