# =============================================================================
# verify.ps1 - Abschluss-Verifikation aller Komponenten (natives Windows)
#
# Prueft: SSH, noVNC-Tunnel (6080), Cockpit-Tunnel (3847), Mutagen-Session,
# Desktop-App-Eintraege. Gibt pro Komponente OK/FAIL/WARN aus; Exit-Code 1,
# wenn mindestens eine Pflicht-Komponente fehlschlaegt.
#
# PowerShell-5.1-kompatibel. Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File verify.ps1 -VmUser <VM_USER>
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$VmUser
)
$ErrorActionPreference = 'Continue'
$failed = $false

# --- SSH ------------------------------------------------------------------------
& ssh -o BatchMode=yes -o ConnectTimeout=10 ki-os-vm true 2>$null
if ($LASTEXITCODE -eq 0) { Write-Host 'OK:   SSH-Verbindung (ki-os-vm)' }
else { Write-Host 'FAIL: SSH-Verbindung (ki-os-vm) - references/ssh.md -> Smoketest'; $failed = $true }

# --- Watchdog-Task (haelt Tunnel + Mutagen-Daemon am Leben) -----------------------
if (Get-ScheduledTask -TaskName 'ki-os-vm-watchdog' -ErrorAction SilentlyContinue) {
    Write-Host 'OK:   Scheduled Task ki-os-vm-watchdog'
} else {
    Write-Host 'FAIL: Scheduled Task ki-os-vm-watchdog fehlt (setup-tunnels.ps1)'; $failed = $true
}

# --- Tunnel ------------------------------------------------------------------------
foreach ($t in @(
    @{ Label = 'noVNC-Tunnel  http://localhost:6080/vnc.html'; Url = 'http://localhost:6080/vnc.html'; Port = 6080 },
    @{ Label = 'Cockpit-Tunnel http://localhost:3847';          Url = 'http://localhost:3847';          Port = 3847 }
)) {
    $listening = [bool](Get-NetTCPConnection -LocalPort $t.Port -State Listen -ErrorAction SilentlyContinue)
    $code = $null
    try { $code = (Invoke-WebRequest -UseBasicParsing -Uri $t.Url -TimeoutSec 5).StatusCode } catch {}
    if ($listening -and $code -eq 200) { Write-Host "OK:   $($t.Label) (HTTP $code)" }
    elseif ($listening) { Write-Host "WARN: $($t.Label) - Port lauscht, HTTP-Antwort fehlt (VM-Service? Admin fragen)" }
    else { Write-Host "FAIL: $($t.Label) - Port lauscht nicht (Start-ScheduledTask ki-os-vm-watchdog; references/tunnels.md)"; $failed = $true }
}

# --- Mutagen ------------------------------------------------------------------------
$mutagenCmd = Get-Command mutagen -ErrorAction SilentlyContinue
if (-not $mutagenCmd) { $mutagenCmd = Get-Command (Join-Path $env:USERPROFILE '.local\bin\mutagen.exe') -ErrorAction SilentlyContinue }
if ($mutagenCmd) {
    $status = (& $mutagenCmd.Source sync list ki-os 2>$null) -join ' '
    if ($LASTEXITCODE -eq 0 -and $status -match 'Watching|Scanning|Staging|Reconciling|Saving|Transitioning') {
        Write-Host 'OK:   Mutagen-Session ki-os aktiv'
    } elseif ($LASTEXITCODE -eq 0) {
        Write-Host 'WARN: Mutagen-Session ki-os existiert, Status pruefen: mutagen sync list ki-os'
    } else {
        Write-Host 'FAIL: Mutagen-Session ki-os fehlt (setup-mutagen.ps1)'; $failed = $true
    }
} else {
    Write-Host 'FAIL: mutagen nicht installiert (setup-mutagen.ps1)'; $failed = $true
}
if (Test-Path (Join-Path $env:USERPROFILE 'KI-OS')) { Write-Host 'OK:   Lokaler Workspace %USERPROFILE%\KI-OS vorhanden' }
else { Write-Host 'FAIL: Lokaler Workspace %USERPROFILE%\KI-OS fehlt'; $failed = $true }

# --- Desktop-App -----------------------------------------------------------------------
$cfgPath = Join-Path $env:APPDATA 'Claude\ssh_configs.json'
if ((Test-Path $cfgPath) -and ((Get-Content -LiteralPath $cfgPath -Raw) -match '"ki-os-vm"')) {
    Write-Host 'OK:   Desktop-App ssh_configs.json (ki-os-vm)'
} else {
    Write-Host 'WARN: Desktop-App-Host nicht registriert (App nicht installiert? register-desktop-app.ps1)'
}
$settings = Join-Path $env:USERPROFILE '.claude.json'
if ((Test-Path $settings) -and ((Get-Content -LiteralPath $settings -Raw) -match [regex]::Escape("ssh:ki-os-vm:/home/$VmUser/KI-OS"))) {
    Write-Host 'OK:   ~\.claude.json Workspace-Eintrag'
} else {
    Write-Host "WARN: ~\.claude.json Workspace-Eintrag fehlt (register-desktop-app.ps1 wiederholen, nachdem 'claude' einmal lief)"
}

if ($failed) { exit 1 } else { exit 0 }
