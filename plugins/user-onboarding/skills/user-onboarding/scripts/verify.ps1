# =============================================================================
# verify.ps1 - Abschluss-Verifikation aller Komponenten (natives Windows)
#
# Prueft: SSH, die Gateway-URLs je Engine-Paket (Claude-Paket: Cockpit + VM-Desktop
# (noVNC); Hermes-Paket: Agent-URL der Hermes-Desktop-App), die Artefakte und die
# Claude-Desktop-App-Eintraege. Gibt pro Komponente OK/FAIL/WARN aus; Exit-Code 1,
# wenn mindestens eine Pflicht-Komponente fehlschlaegt.
#
# PowerShell-5.1-kompatibel. Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File verify.ps1 -VmUser <VM_USER> `
#       -Packages <hermes|claude|hermes,claude>
#       [-GatewayCockpitUrl <url>] [-GatewayNovncUrl <url>] [-GatewayAgentUrl <url>] [-GatewayAppsUrl <url>]
#
# Pakete und URLs kommen aus get-vm-values (PACKAGES=, GATEWAY_*_URL=). Der Check
# laeuft unauthentifiziert: 302/401/403 = OK (Login kommt vom IdP), 200 waere ein
# Auth-Bypass.
#
# Claude-Paket: Cockpit, VM-Desktop und die Desktop-App-Eintraege. Ohne
# -GatewayNovncUrl kein VM-Desktop-Check (Option display aus, DISPLAY_STACK=AUS).
# Hermes-Paket: die Agent-URL; die Hermes-App verbindet sich mit URL +
# Firmen-Login, lokal gibt es keine Registrierung zu pruefen.
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$VmUser,
    [Parameter(Mandatory = $true)][string]$Packages,
    [string]$GatewayCockpitUrl = '',
    [string]$GatewayNovncUrl = '',
    [string]$GatewayAgentUrl = '',
    [string]$GatewayAppsUrl = ''
)
$ErrorActionPreference = 'Continue'
$failed = $false
$hasClaude = $false
$hasHermes = $false
foreach ($p in ($Packages -split '[, ]+' | Where-Object { $_ })) {
    switch ($p) {
        'claude' { $hasClaude = $true }
        'hermes' { $hasHermes = $true }
        default  { Write-Host "FAIL: -Packages kennt nur hermes und claude (nicht '$p')"; exit 2 }
    }
}
if (-not ($hasClaude -or $hasHermes)) { Write-Host 'FAIL: -Packages fehlt (PACKAGES= aus get-vm-values)'; exit 2 }

# --- SSH ------------------------------------------------------------------------
& ssh -o BatchMode=yes -o ConnectTimeout=10 ki-os-vm true 2>$null
if ($LASTEXITCODE -eq 0) { Write-Host 'OK:   SSH-Verbindung (ki-os-vm)' }
else { Write-Host 'FAIL: SSH-Verbindung (ki-os-vm) - references/ssh.md -> Smoketest'; $failed = $true }

# --- Gateway-URLs ---------------------------------------------------------------
# Oberflaechen je Paket - EIN Ort; Artefakte liefert der Kern fuer jedes Paket.
# Unauthentifiziert MUSS ein Redirect/Deny kommen (302/401/403).
# 200 waere ein Auth-Bypass -> Admin alarmieren.
$gwChecks = @()
if ($hasClaude) {
    $gwChecks += @{ Label = 'Gateway Cockpit'; Url = $GatewayCockpitUrl }
    if ($GatewayNovncUrl) { $gwChecks += @{ Label = 'Gateway noVNC'; Url = $GatewayNovncUrl } }
}
if ($hasHermes) { $gwChecks += @{ Label = 'Gateway Hermes-Agent'; Url = $GatewayAgentUrl } }
$gwChecks += @{ Label = 'Gateway Artefakte'; Url = $GatewayAppsUrl }
foreach ($g in $gwChecks) {
    if (-not $g.Url -or $g.Url -eq 'MISSING') {
        Write-Host "FAIL: $($g.Label)-URL fehlt (Admin: ki-os-fleet vm gateway-grant)"; $failed = $true
        continue
    }
    $code = $null
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri $g.Url -TimeoutSec 10 -MaximumRedirection 0
        $code = $resp.StatusCode
    } catch {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    }
    if ($code -in @(302, 401, 403)) { Write-Host "OK:   $($g.Label) $($g.Url) (HTTP $code -> IdP-Login)" }
    elseif ($code -eq 200) { Write-Host "FAIL: $($g.Label) $($g.Url) liefert unauthentifiziert HTTP 200 - Admin SOFORT informieren"; $failed = $true }
    else { Write-Host "FAIL: $($g.Label) $($g.Url) (HTTP $code / keine Antwort)"; $failed = $true }
}

# --- Desktop-Apps -----------------------------------------------------------------
if ($hasHermes) {
    Write-Host 'OK:   Hermes-Paket - lokal nichts zu registrieren (Hermes-Desktop-App:'
    Write-Host '      Remote gateway -> Agent-URL + Firmen-Login; Anmeldungen: Desktop-App ->'
    Write-Host "      Screen -> Uebernehmen; URL beim Admin: ki-os-fleet vm zugang --user $VmUser)"
}
# Die Registrierung (ssh_configs.json + ~\.claude.json) gehoert allein zum Claude-Paket.
if (-not $hasClaude) {
    if ($failed) { exit 1 } else { exit 0 }
}

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
