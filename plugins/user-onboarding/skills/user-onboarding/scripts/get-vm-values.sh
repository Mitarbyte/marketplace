#!/usr/bin/env bash
# get-vm-values.sh — Smoketest + pro-User-Werte in EINEM SSH-Roundtrip
#
# Holt die Engine-Pakete der VM, den Zustand des VM-Desktops (Claude-Paket) und
# die Gateway-URLs des Users. Schlaegt die Verbindung fehl, wird der SSH-Fehler
# ausgegeben (Diagnose: references/ssh.md).
#
# Usage:  get-vm-values.sh
# Nicht auf Pfad H (nur Hermes-Paket, ADR 22 Nr. 10): dort gibt es keinen
# SSH-Zugang vom Geraet — die URLs kommen aus `ki-os-fleet vm zugang`.
#
# Output-Marker:
#   SSH_OK | SSH_FAIL: <fehler>
#   PACKAGES=<hermes|claude|hermes,claude>  Engine-Pakete der VM (ki-os-engine
#          --packages; VMs vor dem Rollout: Rueckfall auf die Praesenz der Pakete)
#   Claude-Paket:  GATEWAY_COCKPIT_URL=<url|MISSING>
#                  DISPLAY_STACK=<OK|MISSING|AUS>  VM-Desktop (noVNC); AUS = Option
#                                                  display aus, dann ohne noVNC-URL
#                  GATEWAY_NOVNC_URL=<url|MISSING>
#   Hermes-Paket:  GATEWAY_AGENT_URL=<url|MISSING>  (Hermes-Desktop-App + Dashboard)
#   immer:         GATEWAY_APPS_URL=<url|MISSING>   (Artefakte hinter dem Firmen-Login)
# Ein VNC-Passwort gibt es nicht: x11vnc laeuft mit -nopw, der Zugang ist der
# Firmen-Login am Gateway (ADR § 5.6).
set -uo pipefail

OUT="$(ssh -o BatchMode=yes -o ConnectTimeout=10 ki-os-vm bash -s 2>&1 <<'REMOTE'
set -u
# Pakete aus der EINEN Auswahlstelle. Aeltere VMs kennen --packages nicht
# (Exit 2, leere Ausgabe): dann zaehlt, welches Paket auf der VM liegt.
pk=""
if [ -x /usr/local/bin/ki-os-engine ]; then
    for p in $(/usr/local/bin/ki-os-engine --packages 2>/dev/null); do
        case "$p" in hermes|claude) pk="${pk:+$pk,}$p" ;; esac
    done
fi
if [ -z "$pk" ]; then
    # Hermes: eigener Checkout oder der VM-Code (ADR 29)
    { [ -d ~/.hermes/hermes-agent ] || [ -d /usr/local/lib/hermes-agent ]; } && pk="hermes"
    if [ -x /usr/local/bin/mitarbyte ] || systemctl cat "mitarbyte-cockpit@$(id -un).service" >/dev/null 2>&1; then
        pk="${pk:+$pk,}claude"
    fi
fi
echo "PACKAGES=${pk}"
gw() { v="$(grep "^$1=" ~/.config/ki-os/gateway.env 2>/dev/null | head -1 | cut -d= -f2-)"; echo "$1=${v:-MISSING}"; }
case ",${pk}," in *,claude,*)
    gw GATEWAY_COCKPIT_URL
    if grep -qx aus /opt/mitarbyte/claude/display 2>/dev/null; then
        echo "DISPLAY_STACK=AUS"
    else
        if grep -q '^NOVNC_PORT=' ~/.config/ki-os/display.env 2>/dev/null; then echo "DISPLAY_STACK=OK"; else echo "DISPLAY_STACK=MISSING"; fi
        gw GATEWAY_NOVNC_URL
    fi ;;
esac
case ",${pk}," in *,hermes,*) gw GATEWAY_AGENT_URL ;; esac
gw GATEWAY_APPS_URL
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

# Auswertung ohne Paket-Logik: der Remote-Block nennt nur die URLs, die die
# Pakete dieser VM haben — jedes MISSING ist ein fehlendes Mapping.
echo "$OUT" | grep -qx 'PACKAGES=' \
    && echo "WARN: keine Engine-Pakete auf der VM erkannt — Admin kontaktieren."
echo "$OUT" | grep -q '^DISPLAY_STACK=MISSING' \
    && echo "WARN: display.env fehlt — VM-Desktop fuer diesen User noch nicht provisioniert. Admin kontaktieren, danach hier weitermachen."
echo "$OUT" | sed -n 's/^GATEWAY_\([A-Z]*\)_URL=MISSING$/\1/p' | while read -r k; do
    echo "WARN: kein Gateway-Mapping (${k}) fuer diesen User — Admin kontaktieren (ki-os-fleet vm gateway-grant)."
done
exit 0
