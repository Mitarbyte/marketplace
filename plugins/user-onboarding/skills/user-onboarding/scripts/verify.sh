#!/usr/bin/env bash
# verify.sh — Abschluss-Verifikation aller Komponenten (macOS/Linux)
#
# Prueft: SSH, die Gateway-URLs je Engine-Paket (Claude-Paket: Cockpit + VM-Desktop
# (noVNC); Hermes-Paket: Agent-URL der Hermes-Desktop-App), die Artefakte und die
# Claude-Desktop-App-Eintraege. Gibt pro Komponente OK/FAIL aus; Exit-Code 1,
# wenn mindestens eine Pflicht-Komponente fehlschlaegt.
#
# Usage:  verify.sh --vm-user <VM_USER> --packages <hermes|claude|hermes,claude>
#                    [--gateway-cockpit-url <url>] [--gateway-novnc-url <url>]
#                    [--gateway-agent-url <url>] [--gateway-apps-url <url>]
#
# Pakete und URLs kommen aus get-vm-values (PACKAGES=, GATEWAY_*_URL=). Der Check
# laeuft unauthentifiziert: 302/401/403 zum IdP-Login = OK, 200 waere ein
# Auth-Bypass.
#
# Claude-Paket: Cockpit, VM-Desktop und die Desktop-App-Eintraege (ssh_configs.json,
# ~/.claude.json). Ohne --gateway-novnc-url kein VM-Desktop-Check (Option
# display aus, get-vm-values meldet DISPLAY_STACK=AUS).
# Hermes-Paket: die Agent-URL; die Hermes-Desktop-App verbindet sich ueber URL +
# Firmen-Login, lokal gibt es keine Registrierung zu pruefen.
set -uo pipefail

VM_USER="" PACKAGES="" GW_COCKPIT_URL="" GW_NOVNC_URL="" GW_AGENT_URL="" GW_APPS_URL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --vm-user)             VM_USER="$2"; shift 2 ;;
        --packages)            PACKAGES="$2"; shift 2 ;;
        --gateway-cockpit-url) GW_COCKPIT_URL="$2"; shift 2 ;;
        --gateway-novnc-url)   GW_NOVNC_URL="$2"; shift 2 ;;
        --gateway-agent-url)   GW_AGENT_URL="$2"; shift 2 ;;
        --gateway-apps-url)    GW_APPS_URL="$2"; shift 2 ;;
        *) echo "FAIL: unbekanntes Argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$VM_USER" ] || { echo "FAIL: --vm-user fehlt" >&2; exit 2; }
HAS_CLAUDE=0 HAS_HERMES=0
for p in $(echo "$PACKAGES" | tr ', ' '  '); do
    case "$p" in
        claude) HAS_CLAUDE=1 ;;
        hermes) HAS_HERMES=1 ;;
        *) echo "FAIL: --packages kennt nur hermes und claude (nicht '$p')" >&2; exit 2 ;;
    esac
done
[ "$HAS_CLAUDE$HAS_HERMES" != "00" ] || { echo "FAIL: --packages fehlt (PACKAGES= aus get-vm-values)" >&2; exit 2; }

# Gateway-Oberflaechen je Paket — EIN Ort: "Label|Gateway-URL", eine Zeile je
# Oberflaeche. Artefakte liefert der Kern fuer jedes Paket.
SURFACES=""
add() { SURFACES="${SURFACES}${SURFACES:+
}$1"; }
if [ "$HAS_CLAUDE" = 1 ]; then
    add "Cockpit|${GW_COCKPIT_URL}"
    [ -z "$GW_NOVNC_URL" ] || add "noVNC|${GW_NOVNC_URL}"
fi
[ "$HAS_HERMES" = 1 ] && add "Hermes-Agent|${GW_AGENT_URL}"
add "Artefakte|${GW_APPS_URL}"

RC=0
check() { # check <label> <cmd...>
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "OK:   $label"
    else
        echo "FAIL: $label"
        RC=1
    fi
}

check "SSH-Verbindung (ki-os-vm)" ssh -o BatchMode=yes -o ConnectTimeout=10 ki-os-vm true
# Unauthentifiziert MUSS ein Redirect zum IdP-Login kommen (302).
# 200 waere ein Auth-Bypass → Admin alarmieren.
while IFS='|' read -r label url; do
    [ -n "$label" ] || continue
    if [ -z "$url" ] || [ "$url" = "MISSING" ]; then
        echo "FAIL: Gateway-${label}-URL fehlt (Admin: ki-os-fleet vm gateway-grant)"
        RC=1
        continue
    fi
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || true)"
    case "$code" in
        302|401|403) echo "OK:   Gateway ${label} ${url} (HTTP ${code} → IdP-Login)" ;;
        200) echo "FAIL: Gateway ${label} ${url} liefert unauthentifiziert HTTP 200 — Admin SOFORT informieren"; RC=1 ;;
        *)   echo "FAIL: Gateway ${label} ${url} (HTTP ${code:-keine Antwort})"; RC=1 ;;
    esac
done <<EOF
${SURFACES}
EOF

if [ "$HAS_HERMES" = 1 ]; then
    echo "OK:   Hermes-Paket — lokal nichts zu registrieren (Hermes-Desktop-App:"
    echo "      Remote gateway → Agent-URL + Firmen-Login; Anmeldungen: Desktop-App →"
    echo "      Screen → Übernehmen; URL beim Admin: ki-os-fleet vm zugang --user ${VM_USER})"
fi
# Die Desktop-App-Registrierung (ssh_configs.json + ~/.claude.json) gehoert
# allein zum Claude-Paket.
[ "$HAS_CLAUDE" = 1 ] || exit $RC

if [ "$(uname -s)" = "Darwin" ]; then
    CFG="$HOME/Library/Application Support/Claude/ssh_configs.json"
    if [ -f "$CFG" ] && grep -q '"ki-os-vm"' "$CFG" 2>/dev/null; then
        echo "OK:   Desktop-App ssh_configs.json (ki-os-vm)"
    else
        echo "WARN: Desktop-App-Host nicht registriert (App nicht installiert? register-desktop-app.sh)"
    fi
fi
if [ -f "$HOME/.claude.json" ] && grep -q "ssh:ki-os-vm:/home/${VM_USER}/KI-OS" "$HOME/.claude.json" 2>/dev/null; then
    echo "OK:   ~/.claude.json Workspace-Eintrag"
else
    echo "WARN: ~/.claude.json Workspace-Eintrag fehlt (register-desktop-app.sh wiederholen, nachdem 'claude' einmal lief)"
fi

exit $RC
