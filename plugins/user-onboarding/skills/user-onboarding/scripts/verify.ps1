# =============================================================================
# verify.ps1 - Abschluss-Verifikation aller Komponenten (natives Windows)
#
# Prueft: SSH, noVNC-Tunnel (6080), Agent-Tunnel (Cockpit 3847 bzw. Hermes 9119),
# Mutagen-Session, Desktop-App-Eintraege. Gibt pro Komponente OK/FAIL/WARN aus;
# Exit-Code 1, wenn mindestens eine Pflicht-Komponente fehlschlaegt.
#
# PowerShell-5.1-kompatibel. Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File verify.ps1 -VmUser <VM_USER> `
#       [-Mode tunnel|gateway] [-Engine claude|hermes] [-HubBackend git|cloud]
#       [-GatewayCockpitUrl <url>] [-GatewayNovncUrl <url>] [-GatewayAgentUrl <url>]
#
# -HubBackend cloud (aus get-vm-values HUB_BACKEND): Mutagen ENTFAELLT dort
# komplett (Datei-Einsicht ueber den Cloud-Client der Firma) - die Mutagen-
# Checks werden zum SKIP statt zum Pflicht-FAIL fuer den Soll-Zustand.
#
# -Engine hermes: kein Cockpit und keine Claude-Desktop-App - geprueft werden das
# Hermes-Dashboard (Tunnel 9119 bzw. Gateway-Agent-URL) und SSH/Mutagen. Die
# Hermes-App verbindet sich mit URL + Session-Token, lokal gibt es keine
# Registrierung zu pruefen.
#
# -Mode gateway (aus get-vm-values ACCESS_MODE): statt der lokalen Tunnel
# werden die Gateway-URLs geprueft (302/401/403 = OK, Login kommt vom IdP).
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$VmUser,
    [string]$Mode = 'tunnel',
    [ValidateSet('claude','hermes')][string]$Engine = 'claude',
    [ValidateSet('git','cloud')][string]$HubBackend = 'git',
    [string]$GatewayCockpitUrl = '',
    [string]$GatewayNovncUrl = '',
    [string]$GatewayAgentUrl = ''
)
$ErrorActionPreference = 'Continue'
$failed = $false
$isGateway = ($Mode -eq 'gateway')
$isHermes  = ($Engine -eq 'hermes')
# Haupt-Oberflaeche je Engine - EIN Ort, an dem der Unterschied steht.
if ($isHermes) {
    $mainLabel = 'Hermes-Dashboard'; $mainPort = 9119; $mainGwUrl = $GatewayAgentUrl
} else {
    $mainLabel = 'Cockpit';          $mainPort = 3847; $mainGwUrl = $GatewayCockpitUrl
}

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

# --- Tunnel bzw. Gateway-URLs -------------------------------------------------------
if ($isGateway) {
    # Gateway statt Tunnel: unauthentifiziert MUSS ein Redirect/Deny kommen
    # (302/401/403). 200 waere ein Auth-Bypass -> Admin alarmieren.
    foreach ($g in @(
        @{ Label = "Gateway $mainLabel"; Url = $mainGwUrl },
        @{ Label = 'Gateway noVNC';      Url = $GatewayNovncUrl }
    )) {
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
} else {
    foreach ($t in @(
        @{ Label = 'noVNC-Tunnel  http://localhost:6080/vnc.html'; Url = 'http://localhost:6080/vnc.html'; Port = 6080 },
        @{ Label = "$mainLabel-Tunnel http://localhost:$mainPort"; Url = "http://localhost:$mainPort"; Port = $mainPort }
    )) {
        $listening = [bool](Get-NetTCPConnection -LocalPort $t.Port -State Listen -ErrorAction SilentlyContinue)
        $code = $null
        try { $code = (Invoke-WebRequest -UseBasicParsing -Uri $t.Url -TimeoutSec 5).StatusCode } catch {}
        if ($listening -and $code -eq 200) { Write-Host "OK:   $($t.Label) (HTTP $code)" }
        elseif ($listening) { Write-Host "WARN: $($t.Label) - Port lauscht, HTTP-Antwort fehlt (VM-Service? Admin fragen)" }
        else { Write-Host "FAIL: $($t.Label) - Port lauscht nicht (Start-ScheduledTask ki-os-vm-watchdog; references/tunnels.md)"; $failed = $true }
    }
}

# --- Mutagen ------------------------------------------------------------------------
# Backend cloud: Mutagen ist dort der SOLL-Zustand "nicht vorhanden" - ein
# Pflicht-FAIL fuer die fehlende Session waere falsch. Checks werden zum SKIP;
# laeuft trotzdem eine ki-os-Session (nicht terminierter Uebergang), wird gewarnt.
$mutagenCmd = Get-Command mutagen -ErrorAction SilentlyContinue
if (-not $mutagenCmd) { $mutagenCmd = Get-Command (Join-Path $env:USERPROFILE '.local\bin\mutagen.exe') -ErrorAction SilentlyContinue }
if ($HubBackend -eq 'cloud') {
    Write-Host 'OK:   hub-backend=cloud - Mutagen entfaellt (Datei-Einsicht ueber den Cloud-Client der Firma)'
    if ($mutagenCmd) {
        & $mutagenCmd.Source sync list ki-os 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "WARN: Es laeuft noch eine Mutagen-Session 'ki-os' - auf cloud-Backend gehoert sie"
            Write-Host "      terminiert ('mutagen sync terminate ki-os'), sonst syncen zwei Engines dieselben Bytes."
        }
    }
} else {
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

# Stille Divergenz sichtbar machen: 'Watching for changes' ist NICHT gesund,
# solange Konflikte oder Transition problems anliegen (Lesson 17 + Nachspiel).
$syncLong = ''
if ($mutagenCmd) { $syncLong = (& $mutagenCmd.Source sync list ki-os --long 2>$null) | Out-String }
if ($syncLong) {
    $c = [regex]::Match($syncLong, '(?m)^Conflicts:\s*(\d+)\s*$')
    if ($syncLong -match '(?m)^Conflicts:') {
        $n = if ($c.Success) { $c.Groups[1].Value } else { 'mehrere' }
        Write-Host "WARN: Mutagen-Session hat Konflikte ($n) - 'mutagen sync list ki-os --long'."
        Write-Host '      Meist eine VM-Loeschung, die lokal an ignorierten Resten haengt; der'
        Write-Host '      Watchdog loest das binnen ~2 min selbst (references/mutagen.md).'
    }
    if ($syncLong -match 'Transition problems') {
        Write-Host "WARN: Mutagen-Session hat Transition problems - 'mutagen sync list ki-os --long'."
        Write-Host '      Der Watchdog heilt die NICHT (Symlinks, Unicode-Duplikate, toter Transport).'
    }
}

# Lokalen Workspace-Pfad AUS DER SESSION lesen, nicht %USERPROFILE%\KI-OS
# annehmen: Bestands-Setups haben ihn woanders, dann pruefte der Check einen
# Ordner, der mit dem Sync nichts zu tun hat.
$localRoot = Join-Path $env:USERPROFILE 'KI-OS'
if ($syncLong) {
    $b = [regex]::Match($syncLong, '(?ms)^Beta:\r?\n.*?^\s+URL:\s*(.+?)\r?$')
    if ($b.Success -and $b.Groups[1].Value.Trim()) { $localRoot = $b.Groups[1].Value.Trim() }
}
if (Test-Path -LiteralPath $localRoot) { Write-Host "OK:   Lokaler Workspace $localRoot vorhanden" }
else { Write-Host "FAIL: Lokaler Workspace $localRoot fehlt"; $failed = $true }

# Meldet der Watchdog selbst ein Problem? Das ist der Unterschied zwischen
# "laeuft" und "tut, was er soll" (Lesson 17, Nachspiel: ein blockierter
# Aufloeser lief 8 Tage still ins Leere, weil keiner dieses Signal abfragte).
$wdIssues = Join-Path $env:USERPROFILE '.local\state\ki-os\watchdog-issues.last'
if ((Test-Path -LiteralPath $wdIssues) -and (Get-Item -LiteralPath $wdIssues).Length -gt 0) {
    Write-Host 'WARN: Der Sync-Watchdog meldet ein offenes Problem:'
    Get-Content -LiteralPath $wdIssues | ForEach-Object { Write-Host "      $_" }
} else {
    Write-Host 'OK:   Sync-Watchdog meldet keine offenen Probleme'
}

}  # Ende Mutagen-Block (hub-backend git)

# --- Desktop-App -----------------------------------------------------------------------
# Die Registrierung (ssh_configs.json + ~\.claude.json) ist ein CLAUDE-Artefakt.
# Auf Hermes gibt es sie nicht: die Hermes-App wird mit URL + Session-Token
# verbunden, lokal liegt nichts, was man pruefen koennte.
if ($isHermes) {
    Write-Host 'OK:   engine=hermes - keine Claude-Desktop-App-Registrierung zu pruefen'
    Write-Host "      (Hermes-App: Remote gateway -> URL + Session-Token; Token beim Admin: ki-os-fleet vm hermes-token --user $VmUser)"
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
