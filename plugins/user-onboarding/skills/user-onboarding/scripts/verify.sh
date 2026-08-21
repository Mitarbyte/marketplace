#!/usr/bin/env bash
# =============================================================================
# verify.sh — Abschluss-Verifikation aller Komponenten (macOS/Linux)
#
# Prueft: SSH, noVNC-Tunnel (6080), Agent-Tunnel (Cockpit 3847 bzw. Hermes 9119),
# Mutagen-Session, Desktop-App-Eintraege (macOS). Gibt pro Komponente OK/FAIL
# aus; Exit-Code 1, wenn mindestens eine Pflicht-Komponente fehlschlaegt.
#
# Usage:  verify.sh --vm-user <VM_USER> [--mode tunnel|gateway]
#                    [--engine claude|hermes] [--hub-backend git|cloud]
#                    [--gateway-cockpit-url <url>] [--gateway-novnc-url <url>]
#                    [--gateway-agent-url <url>]
#
# --hub-backend cloud (aus get-vm-values HUB_BACKEND): Mutagen ENTFAELLT dort
# komplett (Datei-Einsicht ueber den Cloud-Client der Firma) — die Mutagen-
# Checks werden zum SKIP statt zum Pflicht-FAIL fuer den Soll-Zustand.
#
# --engine hermes: es gibt kein Cockpit und keine Claude-Desktop-App — geprueft
# werden das Hermes-Dashboard (Tunnel 9119 bzw. Gateway-Agent-URL) und, statt der
# ~/.claude.json-Eintraege, nur SSH/Mutagen (die Hermes-Desktop-App verbindet
# sich ueber URL + Session-Token, es gibt keine lokale Registrierung zu pruefen).
#
# --mode gateway (aus get-vm-values ACCESS_MODE): statt der lokalen Tunnel
# werden die beiden Gateway-URLs geprueft (302 zum IdP-Login = OK — der
# Check laeuft unauthentifiziert). SSH/Mutagen/Desktop-App wie gehabt.
# =============================================================================
set -uo pipefail

VM_USER="" MODE="tunnel" ENGINE="claude" HUB_BACKEND="git" GW_COCKPIT_URL="" GW_NOVNC_URL="" GW_AGENT_URL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --vm-user)             VM_USER="$2"; shift 2 ;;
        --mode)                MODE="$2"; shift 2 ;;
        --engine)              ENGINE="$2"; shift 2 ;;
        --hub-backend)         HUB_BACKEND="$2"; shift 2 ;;
        --gateway-cockpit-url) GW_COCKPIT_URL="$2"; shift 2 ;;
        --gateway-novnc-url)   GW_NOVNC_URL="$2"; shift 2 ;;
        --gateway-agent-url)   GW_AGENT_URL="$2"; shift 2 ;;
        *) echo "FAIL: unbekanntes Argument: $1" >&2; exit 2 ;;
    esac
done
# Haupt-Oberflaeche je Engine — EIN Ort, an dem der Unterschied steht.
if [ "$ENGINE" = "hermes" ]; then
    MAIN_LABEL="Hermes-Dashboard"; MAIN_LPORT=9119; MAIN_GW_URL="$GW_AGENT_URL"
else
    MAIN_LABEL="Cockpit";          MAIN_LPORT=3847; MAIN_GW_URL="$GW_COCKPIT_URL"
fi
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
if [ "$MODE" = "gateway" ]; then
    # Gateway-URLs statt Tunnel: unauthentifiziert MUSS ein Redirect zum
    # IdP-Login kommen (302). 200 waere ein Auth-Bypass → Admin alarmieren.
    for pair in "${MAIN_LABEL}|${MAIN_GW_URL}" "noVNC|${GW_NOVNC_URL}"; do
        label="${pair%%|*}"; url="${pair#*|}"
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
    done
else
    http_check "noVNC-Tunnel  http://localhost:6080/vnc.html" "http://localhost:6080/vnc.html"
    http_check "${MAIN_LABEL}-Tunnel http://localhost:${MAIN_LPORT}" "http://localhost:${MAIN_LPORT}"
fi

# Backend cloud: Mutagen ist dort der SOLL-Zustand "nicht vorhanden" — ein
# Pflicht-FAIL fuer die fehlende Session waere falsch. Alle Mutagen-Checks
# (Session, Konflikte, Workspace-Pfad, Watchdog) werden zum SKIP; laeuft
# trotzdem eine ki-os-Session (nicht terminierter Uebergang), wird gewarnt.
if [ "$HUB_BACKEND" = "cloud" ]; then
    echo "OK:   hub-backend=cloud — Mutagen entfaellt (Datei-Einsicht ueber den Cloud-Client der Firma)"
    if command -v mutagen >/dev/null 2>&1 && mutagen sync list ki-os >/dev/null 2>&1; then
        echo "WARN: Es laeuft noch eine Mutagen-Session 'ki-os' — auf cloud-Backend gehoert sie"
        echo "      terminiert ('mutagen sync terminate ki-os'), sonst syncen zwei Engines dieselben Bytes."
    fi
else

# grep ohne -q (liest bis EOF) statt 'grep -q': sonst dieselbe SIGPIPE-Falle wie
# beim Watchdog-Check unten — unter pipefail wird ein Treffer zu "false".
if command -v mutagen >/dev/null 2>&1 && mutagen sync list ki-os 2>/dev/null | grep -iE 'watching|scanning|staging|reconciling|saving|transitioning' >/dev/null; then
    echo "OK:   Mutagen-Session ki-os aktiv"
elif command -v mutagen >/dev/null 2>&1 && mutagen sync list ki-os >/dev/null 2>&1; then
    echo "WARN: Mutagen-Session ki-os existiert, Status pruefen: mutagen sync list ki-os"
else
    echo "FAIL: Mutagen-Session ki-os fehlt"
    RC=1
fi

# Stille Divergenz sichtbar machen: 'Watching for changes' ist NICHT gesund,
# solange Konflikte oder Transition problems anliegen (Lesson 17 + Nachspiel).
# Der Status allein taugt nicht als Nachweis — genau daran ist ein Ausfall
# 8 Tage unbemerkt geblieben.
if command -v mutagen >/dev/null 2>&1; then
    SYNC_LONG="$(mutagen sync list ki-os --long 2>/dev/null || true)"
    if [ -n "$SYNC_LONG" ]; then
        N_CONF="$(printf '%s\n' "$SYNC_LONG" | sed -n 's/^Conflicts:[[:space:]]*\([0-9]\{1,\}\)$/\1/p' | head -1)"
        printf '%s\n' "$SYNC_LONG" | grep -q '^Conflicts:' && [ -z "$N_CONF" ] && N_CONF="mehrere"
        if [ -n "$N_CONF" ]; then
            echo "WARN: Mutagen-Session hat Konflikte (${N_CONF}) — 'mutagen sync list ki-os --long'."
            echo "      Meist eine VM-Loeschung, die lokal an ignorierten Resten haengt; der"
            echo "      Watchdog loest das binnen ~2 min selbst (references/mutagen.md)."
        fi
        if printf '%s\n' "$SYNC_LONG" | grep -q 'Transition problems'; then
            echo "WARN: Mutagen-Session hat Transition problems — 'mutagen sync list ki-os --long'."
            echo "      Der Watchdog heilt die NICHT (Symlinks, Unicode-Duplikate, toter Transport)."
        fi
    fi
fi

# Lokalen Workspace-Pfad AUS DER SESSION lesen, nicht ~/KI-OS annehmen:
# Bestands-Setups haben ihn woanders (z.B. ~/Desktop/KI-OS), dann pruefte der
# Check einen Ordner, der mit dem Sync nichts zu tun hat.
LOCAL_ROOT=""
if command -v mutagen >/dev/null 2>&1; then
    LOCAL_ROOT="$(mutagen sync list ki-os --long 2>/dev/null \
        | awk '/^Beta:/{f=1;next} f && /URL:/{sub(/^[[:space:]]*URL:[[:space:]]*/,""); print; exit}')"
fi
[ -n "$LOCAL_ROOT" ] || LOCAL_ROOT="$HOME/KI-OS"
check "Lokaler Workspace ${LOCAL_ROOT} vorhanden" test -e "$LOCAL_ROOT"

# Mutagen-Session-Watchdog (Selbstheilung bei paused/halted) — kein Pflicht-FAIL
if [ "$(uname -s)" = "Darwin" ]; then
    # Output erst in eine Variable, dann per case pruefen — NICHT
    # 'launchctl list | grep -q'. Unter 'set -o pipefail' beendet sich grep -q
    # beim ersten Treffer, launchctl stirbt an SIGPIPE (141) und pipefail macht
    # daraus "false", OBWOHL es gematcht hat. Gemessen 2026-08-12: 9 von 10
    # Laeufen meldeten faelschlich "nicht geladen" (Race, abhaengig davon wie
    # viel launchctl noch schreiben will) — der Rat "setup-mutagen.sh erneut
    # laufen lassen" ging also ins Leere, weil alles in Ordnung war.
    WD_LIST="$(launchctl list 2>/dev/null || true)"
    case "$WD_LIST" in
        *ki-os-vm.mutagen-watchdog*)
            echo "OK:   Mutagen-Session-Watchdog (LaunchAgent geladen)" ;;
        *)
            echo "WARN: Mutagen-Session-Watchdog nicht geladen (setup-mutagen.sh erneut laufen lassen)" ;;
    esac
else
    if systemctl --user is-enabled ki-os-mutagen-watchdog.timer >/dev/null 2>&1; then
        echo "OK:   Mutagen-Session-Watchdog (systemd-Timer aktiv)"
    else
        echo "WARN: Mutagen-Session-Watchdog-Timer nicht aktiv (setup-mutagen.sh erneut laufen lassen)"
    fi
fi

# Meldet der Watchdog selbst ein Problem? Das ist der Unterschied zwischen
# "laeuft" und "tut, was er soll" — ein blockierter Aufloeser lief 8 Tage still
# ins Leere, weil niemand dieses Signal abgefragt hat (Lesson 17, Nachspiel).
WD_ISSUES="$HOME/.local/state/ki-os/watchdog-issues.last"
if [ -s "$WD_ISSUES" ]; then
    echo "WARN: Der Sync-Watchdog meldet ein offenes Problem:"
    sed 's/^/      /' "$WD_ISSUES"
else
    echo "OK:   Sync-Watchdog meldet keine offenen Probleme"
fi

fi  # Ende Mutagen-Block (hub-backend git)

# Desktop-App-Registrierung ist ein CLAUDE-Artefakt (ssh_configs.json +
# ~/.claude.json). Auf Hermes gibt es sie nicht: die Hermes-Desktop-App wird mit
# URL + Session-Token verbunden, es liegt lokal nichts, was man pruefen koennte.
if [ "$ENGINE" = "hermes" ]; then
    echo "OK:   engine=hermes — keine Claude-Desktop-App-Registrierung zu pruefen"
    echo "      (Hermes-App: Remote gateway → URL + Session-Token; Token beim Admin:"
    echo "       ki-os-fleet vm hermes-token --user ${VM_USER})"
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
