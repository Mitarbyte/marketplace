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
#   COCKPIT_PORT=<n>  NOVNC_PORT=<n|MISSING>  NOVNC_PASS=<pass|MISSING>
# =============================================================================
set -uo pipefail

OUT="$(ssh -o BatchMode=yes -o ConnectTimeout=10 ki-os-vm bash -s 2>&1 <<'REMOTE'
set -u
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
