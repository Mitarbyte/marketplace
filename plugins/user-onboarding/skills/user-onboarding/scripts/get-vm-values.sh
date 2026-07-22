#!/usr/bin/env bash
# =============================================================================
# get-vm-values.sh — Smoketest + pro-User-Werte in EINEM SSH-Roundtrip
#
# Holt Cockpit-Port, noVNC-Port und noVNC-Passwort von der VM. Schlaegt die
# Verbindung fehl, wird der SSH-Fehler ausgegeben (Diagnose: references/ssh.md).
#
# Usage:  get-vm-values.sh
#
# Output-Marker:
#   SSH_OK | SSH_FAIL: <fehler>
#   ACCESS_MODE=<tunnel|gateway>
#   COCKPIT_PORT=<n>  NOVNC_PORT=<n|MISSING>  NOVNC_PASS=<pass|MISSING>
#   GATEWAY_COCKPIT_URL=<url|MISSING>  GATEWAY_NOVNC_URL=<url|MISSING>   (nur gateway)
# =============================================================================
set -uo pipefail

OUT="$(ssh -o BatchMode=yes -o ConnectTimeout=10 ki-os-vm bash -s 2>&1 <<'REMOTE'
set -u
# Zugangs-Modus der VM (tunnel|gateway) — steuert, ob die Tunnel-Autostarts
# (Schritt 7) eingerichtet werden oder das Browser-Gateway sie ersetzt.
am="$(head -1 /opt/mitarbyte/access-mode 2>/dev/null | tr -d '[:space:]' || true)"
echo "ACCESS_MODE=${am:-tunnel}"
cp="$(mitarbyte cockpit-port 2>/dev/null | grep -oE '3[0-9]{4}' | head -1 || true)"
if [ -z "$cp" ]; then
    cp=$((30000 + $(id -u)))
    echo "WARN: mitarbyte-CLI nicht gefunden — Cockpit-Port aus UID abgeleitet."
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
REMOTE
)"
RC=$?

if [ $RC -ne 0 ]; then
    echo "SSH_FAIL: ${OUT}"
    echo "Diagnose (Permission denied / Timeout / Host-Key): references/ssh.md -> Smoketest."
    exit 1
fi

echo "SSH_OK"
echo "$OUT"

if echo "$OUT" | grep -q '^NOVNC_PORT=MISSING'; then
    echo "WARN: display.env fehlt — Display-Stack fuer diesen User noch nicht provisioniert. Admin kontaktieren, danach hier weitermachen."
fi

if echo "$OUT" | grep -q '^GATEWAY_COCKPIT_URL=MISSING'; then
    echo "WARN: gateway-VM, aber kein Gateway-Mapping fuer diesen User — Admin kontaktieren (ki-os-fleet vm gateway-grant)."
fi
