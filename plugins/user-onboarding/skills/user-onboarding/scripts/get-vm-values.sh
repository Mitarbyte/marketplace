#!/usr/bin/env bash
# get-vm-values.sh — Smoketest + pro-User-Werte in EINEM SSH-Roundtrip
#
# Holt Engine, Zustand des Display-Stacks und die Gateway-URLs des Users von
# der VM. Schlaegt die Verbindung fehl, wird der SSH-Fehler ausgegeben
# (Diagnose: references/ssh.md).
#
# Usage:  get-vm-values.sh
# Nicht auf Pfad H (gateway auf reiner Hermes-VM, ADR 22 Nr. 10): dort gibt es
# keinen SSH-Zugang vom Geraet — die URLs kommen aus `ki-os-fleet vm zugang`.
#
# Output-Marker:
#   SSH_OK | SSH_FAIL: <fehler>
#   ENGINE=<claude|hybrid|hermes> welche Agent-Engine dieser User faehrt. Auf
#          hermes gibt es KEIN Cockpit — der Einstieg ist das Hermes-Dashboard
#          (docs/betrieb/vm-management.md § 8).
#   DISPLAY_STACK=<OK|MISSING>          VM-Desktop (noVNC) fuer diesen User provisioniert?
#   GATEWAY_COCKPIT_URL=<url|MISSING>  GATEWAY_NOVNC_URL=<url|MISSING>
#   GATEWAY_AGENT_URL=<url|MISSING>    (nur Hermes-Stack hermes|hybrid)
#   GATEWAY_APPS_URL=<url|MISSING>     (nur Hermes-Stack: Artefakte hinter dem Firmen-Login)
# Ein VNC-Passwort gibt es nicht: x11vnc laeuft mit -nopw, der Zugang ist der
# Firmen-Login am Gateway (ADR § 5.6).
set -uo pipefail

OUT="$(ssh -o BatchMode=yes -o ConnectTimeout=10 ki-os-vm bash -s 2>&1 <<'REMOTE'
set -u
# Engine dieses Users (VM-Default + Per-User-Override). Fehlt ki-os-engine,
# ist die VM claude — der bisherige Zustand.
eng="claude"
if [ -x /usr/local/bin/ki-os-engine ]; then
    eng="$(/usr/local/bin/ki-os-engine "$(id -un)" 2>/dev/null || echo claude)"
fi
echo "ENGINE=${eng}"
# display.env schreibt der Display-Stack (VM-Desktop hinter dem Gateway).
if grep -q '^NOVNC_PORT=' ~/.config/ki-os/display.env 2>/dev/null; then
    echo "DISPLAY_STACK=OK"
else
    echo "DISPLAY_STACK=MISSING"
fi
gc="$(grep '^GATEWAY_COCKPIT_URL=' ~/.config/ki-os/gateway.env 2>/dev/null | cut -d= -f2- || true)"
gn="$(grep '^GATEWAY_NOVNC_URL=' ~/.config/ki-os/gateway.env 2>/dev/null | cut -d= -f2- || true)"
ga="$(grep '^GATEWAY_AGENT_URL=' ~/.config/ki-os/gateway.env 2>/dev/null | cut -d= -f2- || true)"
gp="$(grep '^GATEWAY_APPS_URL=' ~/.config/ki-os/gateway.env 2>/dev/null | cut -d= -f2- || true)"
echo "GATEWAY_COCKPIT_URL=${gc:-MISSING}"
echo "GATEWAY_NOVNC_URL=${gn:-MISSING}"
# Als `case`, nicht als `[ ... ] && echo`: das Remote-Skript endet hier, und
# eine falsche Bedingung waere sein Exit-Code — der Aufrufer meldete dann
# bei jedem CLAUDE-User faelschlich SSH_FAIL.
case "$eng" in
    hermes|hybrid) echo "GATEWAY_AGENT_URL=${ga:-MISSING}"; echo "GATEWAY_APPS_URL=${gp:-MISSING}" ;;
esac
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

if echo "$OUT" | grep -q '^DISPLAY_STACK=MISSING'; then
    echo "WARN: display.env fehlt — Display-Stack fuer diesen User noch nicht provisioniert. Admin kontaktieren, danach hier weitermachen."
fi

# Gateway-Mapping je Stack: Claude-Stack (claude|hybrid) braucht die Cockpit-URL,
# Hermes-Stack (hermes|hybrid) die Agent-URL — hybrid beide. Auf engine=hermes
# ist GATEWAY_COCKPIT_URL legitim leer (kein Cockpit). Ohne diese Unterscheidung
# wuerde der Skill jedem Hermes-User ein "kein Gateway-Mapping" vorwerfen.
_eng="$(echo "$OUT" | sed -n 's/^ENGINE=//p' | head -1)"
case "$_eng" in
    claude|hybrid)
        echo "$OUT" | grep -q '^GATEWAY_COCKPIT_URL=MISSING' \
            && echo "WARN: gateway-VM, aber kein Gateway-Mapping (Cockpit) fuer diesen User — Admin kontaktieren (ki-os-fleet vm gateway-grant)." ;;
esac
case "$_eng" in
    hermes|hybrid)
        echo "$OUT" | grep -q '^GATEWAY_AGENT_URL=MISSING' \
            && echo "WARN: gateway-VM, aber kein Gateway-Mapping (Agent-Dashboard) fuer diesen User — Admin kontaktieren (ki-os-fleet vm gateway-grant)."
        echo "$OUT" | grep -q '^GATEWAY_APPS_URL=MISSING' \
            && echo "WARN: gateway-VM, aber kein Apps-Mapping (Artefakte) fuer diesen User — Admin kontaktieren (ki-os-fleet vm gateway-grant)." ;;
esac
exit 0
