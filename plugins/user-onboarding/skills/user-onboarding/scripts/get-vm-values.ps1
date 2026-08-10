# =============================================================================
# get-vm-values.ps1 - Smoketest + pro-User-Werte in EINEM SSH-Roundtrip (Windows)
#
# Holt Engine, Cockpit-/Agent-Port, noVNC-Port und (nur im tunnel-Modus) das
# noVNC-Passwort von der VM. Schlaegt die Verbindung fehl, wird der SSH-Fehler
# ausgegeben (Diagnose: references/ssh.md).
#
# PowerShell-5.1-kompatibel. Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File get-vm-values.ps1
#
# Output-Marker: SSH_OK | SSH_FAIL, ACCESS_MODE=,
#                ENGINE= (claude|hermes - auf hermes gibt es KEIN Cockpit; der
#                Einstieg ist das Hermes-Dashboard auf AGENT_PORT, und im
#                tunnel-Modus wird dieser Port getunnelt statt 3847),
#                AGENT_PORT= (Hermes-Dashboard-Port, nur relevant auf hermes),
#                COCKPIT_PORT= / NOVNC_PORT= /
#                NOVNC_PASS= (NOT_NEEDED im gateway-Modus: x11vnc laeuft dort
#                mit -nopw, ADR 5.6 - das Passwort wird bewusst nicht gelesen),
#                GATEWAY_COCKPIT_URL= / GATEWAY_NOVNC_URL= (nur gateway),
#                GATEWAY_AGENT_URL= (nur gateway + engine=hermes)
# =============================================================================
$ErrorActionPreference = 'Continue'

$remote = @'
set -u
am="$(head -1 /opt/mitarbyte/access-mode 2>/dev/null | tr -d '[:space:]' || true)"
echo "ACCESS_MODE=${am:-tunnel}"
# Engine dieses Users (VM-Default + Per-User-Override). Fehlt ki-os-engine,
# ist die VM claude - der bisherige Zustand.
eng="claude"
if [ -x /usr/local/bin/ki-os-engine ]; then
    eng="$(/usr/local/bin/ki-os-engine "$(id -un)" 2>/dev/null || echo claude)"
fi
echo "ENGINE=${eng}"
echo "AGENT_PORT=$((9119 + $(id -u) - 1000))"
cp="$(mitarbyte cockpit-port 2>/dev/null | grep -oE '3[0-9]{4}' | head -1 || true)"
if [ -z "$cp" ]; then
    cp=$((30000 + $(id -u)))
    # Auf hermes fehlt der Cockpit-Port legitim (kein Cockpit) - kein WARN.
    [ "$eng" = "hermes" ] || echo "WARN: mitarbyte-CLI nicht gefunden - Cockpit-Port aus UID abgeleitet."
fi
np="$(grep '^NOVNC_PORT=' ~/.config/ki-os/display.env 2>/dev/null | cut -d= -f2 || true)"
echo "COCKPIT_PORT=${cp}"
echo "NOVNC_PORT=${np:-MISSING}"
# Passwort NUR im tunnel-Modus lesen - im gateway-Modus laeuft x11vnc mit -nopw.
if [ "${am:-tunnel}" = "gateway" ]; then
    echo "NOVNC_PASS=NOT_NEEDED"
    gc="$(grep '^GATEWAY_COCKPIT_URL=' ~/.config/ki-os/gateway.env 2>/dev/null | cut -d= -f2- || true)"
    gn="$(grep '^GATEWAY_NOVNC_URL=' ~/.config/ki-os/gateway.env 2>/dev/null | cut -d= -f2- || true)"
    ga="$(grep '^GATEWAY_AGENT_URL=' ~/.config/ki-os/gateway.env 2>/dev/null | cut -d= -f2- || true)"
    echo "GATEWAY_COCKPIT_URL=${gc:-MISSING}"
    echo "GATEWAY_NOVNC_URL=${gn:-MISSING}"
    # Als `if`, nicht als `[ ... ] && echo`: das Remote-Skript endet hier, und
    # eine falsche Bedingung waere sein Exit-Code - der $LASTEXITCODE-Check
    # meldete dann bei jedem claude-User faelschlich SSH_FAIL.
    if [ "$eng" = "hermes" ]; then
        echo "GATEWAY_AGENT_URL=${ga:-MISSING}"
    fi
else
    pw="$(cat ~/.config/ki-os/vnc.pass 2>/dev/null || true)"
    echo "NOVNC_PASS=${pw:-MISSING}"
fi
'@ -replace "`r`n", "`n"

$out = $remote | & ssh -o BatchMode=yes -o ConnectTimeout=10 ki-os-vm bash -s 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "SSH_FAIL: $($out -join ' | ')"
    Write-Host "Diagnose (Permission denied / Timeout / Host-Key / Bad owner): references/ssh.md -> Smoketest."
    exit 1
}

Write-Host "SSH_OK"
$out | ForEach-Object { Write-Host $_ }

if ($out -match 'NOVNC_PORT=MISSING') {
    Write-Host "WARN: display.env fehlt - Display-Stack fuer diesen User noch nicht provisioniert. Admin kontaktieren, danach hier weitermachen."
}

# Auf engine=hermes ist GATEWAY_COCKPIT_URL legitim leer (kein Cockpit) - dort
# zaehlt GATEWAY_AGENT_URL. Ohne diese Unterscheidung wuerde der Skill jedem
# Hermes-User ein "kein Gateway-Mapping" vorwerfen, obwohl alles stimmt.
if ($out -match 'ENGINE=hermes') {
    if ($out -match 'GATEWAY_AGENT_URL=MISSING') {
        Write-Host "WARN: gateway-VM, aber kein Gateway-Mapping fuer diesen User - Admin kontaktieren (ki-os-fleet vm gateway-grant)."
    }
} elseif ($out -match 'GATEWAY_COCKPIT_URL=MISSING') {
    Write-Host "WARN: gateway-VM, aber kein Gateway-Mapping fuer diesen User - Admin kontaktieren (ki-os-fleet vm gateway-grant)."
}
