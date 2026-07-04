#!/usr/bin/env bash
# =============================================================================
# verify.sh — Abschluss-Verifikation aller Komponenten (macOS/Linux)
#
# Prueft: SSH, noVNC-Tunnel (6080), Cockpit-Tunnel (3847), Mutagen-Session,
# Desktop-App-Eintraege (macOS). Gibt pro Komponente OK/FAIL aus; Exit-Code 1,
# wenn mindestens eine Pflicht-Komponente fehlschlaegt.
#
# Usage:  verify.sh --vm-user <VM_USER>
# =============================================================================
set -uo pipefail

VM_USER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --vm-user) VM_USER="$2"; shift 2 ;;
        *) echo "FAIL: unbekanntes Argument: $1" >&2; exit 2 ;;
    esac
done
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

http_check() { # http_check <label> <url>
    local label="$1" url="$2" code
    code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)"
    if [ "$code" = "200" ] || [ "${code:0:1}" = "3" ]; then
        echo "OK:   $label (HTTP $code)"
    else
        echo "FAIL: $label (HTTP ${code:-keine Antwort})"
        RC=1
    fi
}

check "SSH-Verbindung (ki-os-vm)" ssh -o BatchMode=yes -o ConnectTimeout=10 ki-os-vm true
http_check "noVNC-Tunnel  http://localhost:6080/vnc.html" "http://localhost:6080/vnc.html"
http_check "Cockpit-Tunnel http://localhost:3847"          "http://localhost:3847"

if command -v mutagen >/dev/null 2>&1 && mutagen sync list ki-os 2>/dev/null | grep -qiE 'watching|scanning|staging|reconciling|saving|transitioning'; then
    echo "OK:   Mutagen-Session ki-os aktiv"
elif command -v mutagen >/dev/null 2>&1 && mutagen sync list ki-os >/dev/null 2>&1; then
    echo "WARN: Mutagen-Session ki-os existiert, Status pruefen: mutagen sync list ki-os"
else
    echo "FAIL: Mutagen-Session ki-os fehlt"
    RC=1
fi
check "Lokaler Workspace ~/KI-OS vorhanden" test -e "$HOME/KI-OS"

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
