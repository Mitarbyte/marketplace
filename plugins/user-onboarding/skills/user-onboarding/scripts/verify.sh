#!/usr/bin/env bash
# verify.sh — Abschluss-Verifikation aller Komponenten (macOS/Linux)
#
# Prueft: SSH, die Gateway-URLs der Agenten-Oberflaechen (Cockpit bzw.
# Hermes-Dashboard, auf dem Hermes-Stack zusaetzlich Artefakte), den VM-Desktop
# (noVNC) und die Desktop-App-Eintraege (macOS). Gibt pro Komponente OK/FAIL aus;
# Exit-Code 1, wenn mindestens eine Pflicht-Komponente fehlschlaegt.
#
# Usage:  verify.sh --vm-user <VM_USER> [--engine claude|hybrid|hermes]
#                    [--gateway-cockpit-url <url>] [--gateway-novnc-url <url>]
#                    [--gateway-agent-url <url>] [--gateway-apps-url <url>]
#
# Die URLs kommen aus get-vm-values. Der Check laeuft unauthentifiziert:
# 302/401/403 zum IdP-Login = OK, 200 waere ein Auth-Bypass.
#
# --engine hermes: es gibt kein Cockpit und keine Claude-Desktop-App — geprueft
# werden das Hermes-Dashboard (Gateway-Agent-URL) und, statt der
# ~/.claude.json-Eintraege, nur SSH (die Hermes-Desktop-App verbindet sich ueber
# URL + Firmen-Login, es gibt keine lokale Registrierung zu pruefen).
# --engine hybrid (ADR 18): beide Stacks — Cockpit UND Hermes-Dashboard werden
# geprueft, die Claude-Desktop-App wie auf claude.
set -uo pipefail

VM_USER="" ENGINE="claude" GW_COCKPIT_URL="" GW_NOVNC_URL="" GW_AGENT_URL="" GW_APPS_URL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --vm-user)             VM_USER="$2"; shift 2 ;;
        --engine)              ENGINE="$2"; shift 2 ;;
        --gateway-cockpit-url) GW_COCKPIT_URL="$2"; shift 2 ;;
        --gateway-novnc-url)   GW_NOVNC_URL="$2"; shift 2 ;;
        --gateway-agent-url)   GW_AGENT_URL="$2"; shift 2 ;;
        --gateway-apps-url)    GW_APPS_URL="$2"; shift 2 ;;
        *) echo "FAIL: unbekanntes Argument: $1" >&2; exit 2 ;;
    esac
done
case "$ENGINE" in claude|hybrid|hermes) ;; *) echo "FAIL: --engine erlaubt nur claude|hybrid|hermes" >&2; exit 2 ;; esac
# Agenten-Oberflaechen je Stack — EIN Ort, an dem der Unterschied steht:
# "Label|Gateway-URL", eine Zeile je Oberflaeche (hybrid: zwei).
SURFACES=""
case "$ENGINE" in claude|hybrid) SURFACES="Cockpit|${GW_COCKPIT_URL}" ;; esac
case "$ENGINE" in hermes|hybrid) SURFACES="${SURFACES}${SURFACES:+
}Hermes-Dashboard|${GW_AGENT_URL}" ;; esac
# Artefakte (Hermes-Stack): eigener Apps-Vhost. Auf claude liefert der
# Cockpit-Proxy (/a/) — kein eigener Weg.
HAS_ARTIFACTS=0; case "$ENGINE" in hermes|hybrid) HAS_ARTIFACTS=1 ;; esac
HAS_CLAUDE=0; case "$ENGINE" in claude|hybrid) HAS_CLAUDE=1 ;; esac
[ -n "$VM_USER" ] || { echo "FAIL: --vm-user fehlt" >&2; exit 2; }

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
noVNC|${GW_NOVNC_URL}
$( [ "$HAS_ARTIFACTS" = "1" ] && echo "Artefakte|${GW_APPS_URL}" )
EOF

# Desktop-App-Registrierung ist ein CLAUDE-Artefakt (ssh_configs.json +
# ~/.claude.json). Auf Hermes gibt es sie nicht: die Hermes-Desktop-App wird mit
# URL + Firmen-Login verbunden, es liegt lokal nichts, was man pruefen koennte.
if [ "$HAS_CLAUDE" != "1" ]; then
    echo "OK:   engine=hermes — keine Claude-Desktop-App-Registrierung zu pruefen"
    echo "      (Hermes-App: Remote gateway → URL + Firmen-Login; URL beim Admin:"
    echo "       ki-os-fleet vm zugang --user ${VM_USER})"
    exit $RC
fi

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
