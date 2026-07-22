# =============================================================================
# get-vm-values.ps1 - Smoketest + pro-User-Werte in EINEM SSH-Roundtrip (Windows)
#
# Holt Cockpit-Port, noVNC-Port und noVNC-Passwort von der VM. Schlaegt die
# Verbindung fehl, wird der SSH-Fehler ausgegeben (Diagnose: references/ssh.md).
#
# PowerShell-5.1-kompatibel. Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File get-vm-values.ps1
#
# Output-Marker: SSH_OK | SSH_FAIL, ACCESS_MODE=, COCKPIT_PORT= / NOVNC_PORT= /
#                NOVNC_PASS=, GATEWAY_COCKPIT_URL= / GATEWAY_NOVNC_URL= (nur gateway)
# =============================================================================
$ErrorActionPreference = 'Continue'

$remote = @'
set -u
am="$(head -1 /opt/mitarbyte/access-mode 2>/dev/null | tr -d '[:space:]' || true)"
echo "ACCESS_MODE=${am:-tunnel}"
cp="$(mitarbyte cockpit-port 2>/dev/null | grep -oE '3[0-9]{4}' | head -1 || true)"
if [ -z "$cp" ]; then
    cp=$((30000 + $(id -u)))
    echo "WARN: mitarbyte-CLI nicht gefunden - Cockpit-Port aus UID abgeleitet."
fi
np="$(grep '^NOVNC_PORT=' ~/.config/ki-os/display.env 2>/dev/null | cut -d= -f2 || true)"
pw="$(cat ~/.config/ki-os/vnc.pass 2>/dev/null || true)"
echo "COCKPIT_PORT=${cp}"
echo "NOVNC_PORT=${np:-MISSING}"
echo "NOVNC_PASS=${pw:-MISSING}"
if [ "${am:-tunnel}" = "gateway" ]; then
    gc="$(grep '^GATEWAY_COCKPIT_URL=' ~/.config/ki-os/gateway.env 2>/dev/null | cut -d= -f2 || true)"
    gn="$(grep '^GATEWAY_NOVNC_URL=' ~/.config/ki-os/gateway.env 2>/dev/null | cut -d= -f2 || true)"
    echo "GATEWAY_COCKPIT_URL=${gc:-MISSING}"
    echo "GATEWAY_NOVNC_URL=${gn:-MISSING}"
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

if ($out -match 'GATEWAY_COCKPIT_URL=MISSING') {
    Write-Host "WARN: gateway-VM, aber kein Gateway-Mapping fuer diesen User - Admin kontaktieren (ki-os-fleet vm gateway-grant)."
}
