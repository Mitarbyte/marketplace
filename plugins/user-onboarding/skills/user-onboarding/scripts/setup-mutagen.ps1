# =============================================================================
# setup-mutagen.ps1 — Mutagen installieren + Daemon-Autostart + Session ki-os
# (natives Windows)
#
#   VM (Alpha, gewinnt Konflikte):  ki-os-vm:/home/<VM_USER>/KI-OS
#   Lokal (Beta):                   %USERPROFILE%\KI-OS
#
# Kein offizielles winget-Paket -> GitHub-Release-Zip nach ~\.local\bin
# (Download mit Retry). Daemon laeuft ueber einen unsichtbaren VBS-Launcher als
# Scheduled Task mit 2-Min-Watchdog (der Daemon-Lock macht den blinden Respawn
# hier leak-frei — anders als bei den Tunneln). `.claude/skills` bleibt auf
# Windows im Ignore (Symlinks brauchen SeCreateSymbolicLinkPrivilege).
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
    if (-not $ok) { Write-Host 'FAIL: Mutagen-Download nach 3 Versuchen fehlgeschlagen — Netz pruefen, Schritt wiederholen.'; exit 1 }

    # PATH erweitern (User-Scope), falls noetig
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($userPath -notlike "*$binDir*") {
        [Environment]::SetEnvironmentVariable('PATH', "$binDir;$userPath", 'User')
    }
    if ($env:PATH -notlike "*$binDir*") { $env:PATH = "$binDir;$env:PATH" }
}
$mutagenVersion = & $mutagenExe version 2>&1
Write-Host "OK: mutagen $mutagenVersion ($mutagenExe)"

# --- 2. Daemon-Autostart (Scheduled Task, unsichtbar) ----------------------------
$taskName = 'mutagen-daemon'
$vbs = Join-Path $binDir 'mutagen-daemon-hidden.vbs'
# Exe-Pfad quoten — Windows-Usernamen koennen Leerzeichen enthalten.
$line = 'CreateObject("WScript.Shell").Run """{0}"" daemon run", 0, False' -f $mutagenExe
Set-Content -Path $vbs -Value $line -Encoding ASCII

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""

# 2-Min-Watchdog wie bei den Tunneln; -RepetitionDuration Pflicht, P9999D statt
# [TimeSpan]::MaxValue (HRESULT 0x80041318).
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 2) `
    -RepetitionDuration (New-TimeSpan -Days 9999)).Repetition

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1)

$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

# Idempotent — evtl. sichtbar gestarteten Daemon + alten Task abloesen
& $mutagenExe daemon stop 2>$null
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal | Out-Null
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 3
Write-Host "OK: Daemon-Autostart (Scheduled Task $taskName, unsichtbar via wscript)"

# --- 3. Session ki-os -------------------------------------------------------------
function New-KiOsSession {
    # VM ist Alpha (gewinnt bei Konflikten), lokal ist Beta. `.claude/skills`
    # bleibt auf Windows im Ignore (Symlink-Privileg) — Details references/mutagen.md.
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
        Write-Host 'SESSION_EXISTS: ki-os laeuft bereits — bei abweichender Konfiguration mit -Recreate neu anlegen.'
    }
} else {
    New-KiOsSession
    Write-Host "SESSION_CREATED: ki-os (VM:/home/$VmUser/KI-OS <-> $env:USERPROFILE\KI-OS)"
}

& $mutagenExe sync list ki-os
