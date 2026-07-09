# =============================================================================
# setup-mutagen.ps1 - Mutagen installieren + Daemon-Autostart + Session ki-os
# (natives Windows)
#
#   VM (Alpha, gewinnt Konflikte):  ki-os-vm:/home/<VM_USER>/KI-OS
#   Lokal (Beta):                   %USERPROFILE%\KI-OS
#
# Kein offizielles winget-Paket -> GitHub-Release-Zip nach ~\.local\bin
# (Download mit Retry). Der Daemon-Autostart laeuft NICHT ueber einen eigenen
# Task, sondern ueber den gemeinsamen Watchdog-Task ki-os-vm-watchdog aus
# setup-tunnels.ps1 (dessen 2-Min-Guard startet den Daemon unsichtbar, sobald
# mutagen installiert ist). `.claude/skills` bleibt auf Windows im Ignore
# (Symlinks brauchen SeCreateSymbolicLinkPrivilege).
# Details: references/mutagen.md.
#
# PowerShell-5.1-kompatibel. Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File setup-mutagen.ps1 `
#       -VmUser <VM_USER> [-Recreate]
#
# Output-Marker: SESSION_EXISTS | SESSION_CREATED | SESSION_RECREATED
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$VmUser,
    [switch]$Recreate
)
$ErrorActionPreference = 'Stop'

$binDir     = Join-Path $env:USERPROFILE '.local\bin'
$mutagenExe = Join-Path $binDir 'mutagen.exe'
New-Item -ItemType Directory -Path $binDir -Force | Out-Null

# --- 1. Installieren (mit Retry) -----------------------------------------------
$mutagenCmd = Get-Command mutagen -ErrorAction SilentlyContinue
if ($mutagenCmd) { $mutagenExe = $mutagenCmd.Source }

if (-not (Test-Path $mutagenExe)) {
    $ok = $false
    for ($i = 1; $i -le 3 -and -not $ok; $i++) {
        try {
            $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/mutagen-io/mutagen/releases/latest' -TimeoutSec 30
            $url = ($rel.assets | Where-Object { $_.name -match 'windows_amd64.*\.zip$' -and $_.name -notmatch 'sidecar' })[0].browser_download_url
            $zip = Join-Path $env:TEMP 'mutagen.zip'
            Invoke-WebRequest -Uri $url -OutFile $zip -TimeoutSec 300
            Expand-Archive -Path $zip -DestinationPath $binDir -Force
            Remove-Item $zip -ErrorAction SilentlyContinue
            $ok = $true
        } catch {
            Write-Host "WARN: Download-Versuch $i/3 fehlgeschlagen: $($_.Exception.Message)"
            Start-Sleep -Seconds (5 * $i)
        }
    }
    if (-not $ok) { Write-Host 'FAIL: Mutagen-Download nach 3 Versuchen fehlgeschlagen - Netz pruefen, Schritt wiederholen.'; exit 1 }

    # PATH erweitern (User-Scope), falls noetig
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($userPath -notlike "*$binDir*") {
        [Environment]::SetEnvironmentVariable('PATH', "$binDir;$userPath", 'User')
    }
    if ($env:PATH -notlike "*$binDir*") { $env:PATH = "$binDir;$env:PATH" }
}
$mutagenVersion = & $mutagenExe version 2>&1
Write-Host "OK: mutagen $mutagenVersion ($mutagenExe)"

# --- 2. Daemon-Autostart (uebernimmt der Watchdog-Task) --------------------------
# Den Autostart faehrt der gemeinsame Scheduled Task ki-os-vm-watchdog aus
# setup-tunnels.ps1: sein 2-Min-Guard startet den Daemon unsichtbar, sobald
# mutagen installiert ist und kein Daemon laeuft (Daemon-Lock als Backstop).
# Hier nur: evtl. sichtbar gestarteten Daemon abloesen, den frueheren
# Einzel-Task mutagen-daemon aufraeumen, Watchdog anstossen.
$watchdog = 'ki-os-vm-watchdog'
& $mutagenExe daemon stop 2>$null
if (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName 'mutagen-daemon' -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $binDir 'mutagen-daemon-hidden.vbs') -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $watchdog
    Start-Sleep -Seconds 5
    Write-Host "OK: Daemon-Autostart via Scheduled Task $watchdog (setup-tunnels.ps1)"
} else {
    # setup-tunnels.ps1 (Schritt 7) noch nicht gelaufen - Daemon fuer diese
    # Session direkt starten; der Autostart entsteht mit dem Watchdog-Task.
    Write-Host "WARN: Scheduled Task $watchdog fehlt - setup-tunnels.ps1 nachholen (uebernimmt auch den Mutagen-Daemon-Autostart)."
    Start-Process -WindowStyle Hidden -FilePath $mutagenExe -ArgumentList 'daemon', 'run'
    Start-Sleep -Seconds 3
}

# --- 3. Session ki-os -------------------------------------------------------------
function New-KiOsSession {
    # VM ist Alpha (gewinnt bei Konflikten), lokal ist Beta. `.claude/skills`
    # bleibt auf Windows im Ignore (Symlink-Privileg) - Details references/mutagen.md.
    & $mutagenExe sync create `
        --name=ki-os `
        --sync-mode=two-way-resolved `
        --ignore-vcs `
        --ignore="node_modules" `
        --ignore=".venv" `
        --ignore="__pycache__" `
        --ignore=".obsidian/workspace*" `
        --ignore=".claude/skills" `
        --ignore=".cache" `
        --ignore="dist" `
        --ignore=".next" `
        --ignore=".DS_Store" `
        "ki-os-vm:/home/$VmUser/KI-OS" "$env:USERPROFILE\KI-OS"
}

& $mutagenExe sync list ki-os 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    if ($Recreate) {
        & $mutagenExe sync terminate ki-os
        New-KiOsSession
        Write-Host 'SESSION_RECREATED: ki-os neu angelegt (Dateien bleiben erhalten).'
    } else {
        Write-Host 'SESSION_EXISTS: ki-os laeuft bereits - bei abweichender Konfiguration mit -Recreate neu anlegen.'
    }
} else {
    New-KiOsSession
    Write-Host "SESSION_CREATED: ki-os (VM:/home/$VmUser/KI-OS <-> $env:USERPROFILE\KI-OS)"
}

& $mutagenExe sync list ki-os
