# =============================================================================
# verify.ps1 - Abschluss-Verifikation aller Komponenten (natives Windows)
#
# Prueft: SSH, die Gateway-URLs der Agenten-Oberflaechen (Cockpit bzw.
# Hermes-Dashboard, auf dem Hermes-Stack zusaetzlich Artefakte), den VM-Desktop
# (noVNC) und die Desktop-App-Eintraege. Gibt pro Komponente OK/FAIL/WARN aus;
# Exit-Code 1, wenn mindestens eine Pflicht-Komponente fehlschlaegt.
#
# PowerShell-5.1-kompatibel. Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File verify.ps1 -VmUser <VM_USER> `
#       [-Engine claude|hybrid|hermes]
#       [-GatewayCockpitUrl <url>] [-GatewayNovncUrl <url>] [-GatewayAgentUrl <url>] [-GatewayAppsUrl <url>]
#
# Die URLs kommen aus get-vm-values. Der Check laeuft unauthentifiziert:
# 302/401/403 = OK (Login kommt vom IdP), 200 waere ein Auth-Bypass.
#
# -Engine hermes: kein Cockpit und keine Claude-Desktop-App - geprueft werden das
# Hermes-Dashboard (Gateway-Agent-URL) und SSH. Die Hermes-App verbindet sich mit
# URL + Firmen-Login, lokal gibt es keine Registrierung zu pruefen.
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$VmUser,
    [ValidateSet('claude','hybrid','hermes')][string]$Engine = 'claude',
    [string]$GatewayCockpitUrl = '',
    [string]$GatewayNovncUrl = '',
    [string]$GatewayAgentUrl = '',
    [string]$GatewayAppsUrl = ''
)
$ErrorActionPreference = 'Continue'
$failed = $false
# Stacks (ADR 18): Claude-Stack = claude|hybrid, Hermes-Stack = hermes|hybrid.
$hasClaude = ($Engine -in @('claude','hybrid'))
$hasHermes = ($Engine -in @('hermes','hybrid'))
# Agenten-Oberflaechen je Stack - EIN Ort, an dem der Unterschied steht (hybrid: beide).
$surfaces = @()
if ($hasClaude) { $surfaces += @{ Label = 'Cockpit';          GwUrl = $GatewayCockpitUrl } }
if ($hasHermes) { $surfaces += @{ Label = 'Hermes-Dashboard'; GwUrl = $GatewayAgentUrl } }

# --- SSH ------------------------------------------------------------------------
& ssh -o BatchMode=yes -o ConnectTimeout=10 ki-os-vm true 2>$null
if ($LASTEXITCODE -eq 0) { Write-Host 'OK:   SSH-Verbindung (ki-os-vm)' }
else { Write-Host 'FAIL: SSH-Verbindung (ki-os-vm) - references/ssh.md -> Smoketest'; $failed = $true }

# --- Gateway-URLs ---------------------------------------------------------------
# Unauthentifiziert MUSS ein Redirect/Deny kommen (302/401/403).
# 200 waere ein Auth-Bypass -> Admin alarmieren.
$gwChecks = @()
foreach ($sf in $surfaces) { $gwChecks += @{ Label = "Gateway $($sf.Label)"; Url = $sf.GwUrl } }
$gwChecks += @{ Label = 'Gateway noVNC'; Url = $GatewayNovncUrl }
# Artefakte (Hermes-Stack): eigener Apps-Vhost; auf claude liefert der Cockpit-Proxy.
if ($hasHermes) { $gwChecks += @{ Label = 'Gateway Artefakte'; Url = $GatewayAppsUrl } }
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

# --- Desktop-App -----------------------------------------------------------------------
# Die Registrierung (ssh_configs.json + ~\.claude.json) ist ein CLAUDE-Artefakt.
# Auf Hermes gibt es sie nicht: die Hermes-App wird mit URL + Firmen-Login
# verbunden, lokal liegt nichts, was man pruefen koennte.
if (-not $hasClaude) {
    Write-Host 'OK:   engine=hermes - keine Claude-Desktop-App-Registrierung zu pruefen'
    Write-Host "      (Hermes-App: Remote gateway -> URL + Firmen-Login; URL beim Admin: ki-os-fleet vm zugang --user $VmUser)"
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
