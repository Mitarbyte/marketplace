#!/usr/bin/env bash
# =============================================================================
# setup-tunnels.sh — beide gehaerteten SSH-Tunnel-Autostarts (macOS/Linux)
#
#   noVNC:   lokal 6080 -> VM 127.0.0.1:<NOVNC_PORT>
#   Zweiter Tunnel je Engine (docs/features/hermes/plan.md § 8):
#     engine=claude  Cockpit:        lokal 3847 -> VM 127.0.0.1:<COCKPIT_PORT>
#     engine=hermes  Hermes-Agent:   lokal 9119 -> VM 127.0.0.1:<AGENT_PORT>
#   Lokal 9119 ist bewusst der Hermes-Default: die Desktop-App schlaegt
#   127.0.0.1:9119 von selbst vor, der Mitarbeiter muss nichts umtippen.
#
# Backends: LaunchAgents (macOS, bash-Loop gegen launchd-Parken) bzw.
# systemd-User-Services (Linux, StartLimitIntervalSec=0). Idempotent —
# bestehende Instanzen werden neu geladen statt dupliziert. Haertungs-
# Begruendung: references/tunnels.md.
#
# Usage:  setup-tunnels.sh --novnc-port <VM_PORT> --cockpit-port <VM_PORT>
#         setup-tunnels.sh --novnc-port <VM_PORT> --agent-port <VM_PORT> --engine hermes
#         setup-tunnels.sh --remove
#
# --remove baut beide Tunnel-Autostarts idempotent ab (gateway-Modus: die VM
# stellt noVNC/Cockpit oeffentlich hinter Caddy+Kunden-IdP bereit, lokale
# Tunnel sind obsolet). Mutagen/SSH bleiben unangetastet.
# =============================================================================
set -euo pipefail

NOVNC_PORT="" COCKPIT_PORT="" AGENT_PORT="" ENGINE="claude" REMOVE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --novnc-port)   NOVNC_PORT="$2"; shift 2 ;;
        --cockpit-port) COCKPIT_PORT="$2"; shift 2 ;;
        --agent-port)   AGENT_PORT="$2"; shift 2 ;;
        --engine)       ENGINE="$2"; shift 2 ;;
        --remove)       REMOVE=1; shift ;;
        *) echo "FAIL: unbekanntes Argument: $1" >&2; exit 2 ;;
    esac
done
case "$ENGINE" in claude|hermes) ;; *) echo "FAIL: --engine erlaubt nur claude|hermes" >&2; exit 2 ;; esac

# Zweiter Tunnel: Name, lokaler Port, VM-Port und Verifikations-Pfad haengen an
# der Engine. Alles Weitere (Backends, Haertung, --remove) ist identisch.
if [ "$ENGINE" = "hermes" ]; then
    SECOND_NAME="agent";   SECOND_LPORT=9119; SECOND_RPORT="$AGENT_PORT";   SECOND_LABEL="Hermes-Dashboard"
else
    SECOND_NAME="cockpit"; SECOND_LPORT=3847; SECOND_RPORT="$COCKPIT_PORT"; SECOND_LABEL="Cockpit"
fi

remove_macos_tunnels() {
    local name label plist
    # BEIDE moeglichen Zweit-Tunnel abraeumen, nicht nur den der aktuellen
    # Engine: nach einem Engine-Wechsel liegt der andere sonst als Leiche herum
    # und tunnelt auf einen Port, an dem nichts mehr lauscht.
    for name in novnc cockpit agent; do
        label="com.$(id -un).ssh-tunnel.ki-os-vm-${name}"
        plist="$HOME/Library/LaunchAgents/${label}.plist"
        launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
        [ -f "$plist" ] && rm -f "$plist" && echo "OK: LaunchAgent ${label} entfernt" \
            || echo "OK: LaunchAgent ${label} war nicht vorhanden"
    done
}

remove_linux_tunnels() {
    local name unit
    for name in novnc cockpit agent; do
        unit="ki-os-vm-${name}-tunnel.service"
        systemctl --user disable --now "${unit}" 2>/dev/null || true
        [ -f "$HOME/.config/systemd/user/${unit}" ] \
            && rm -f "$HOME/.config/systemd/user/${unit}" && echo "OK: Unit ${unit} entfernt" \
            || echo "OK: Unit ${unit} war nicht vorhanden"
    done
    systemctl --user daemon-reload 2>/dev/null || true
}

# Nach einem Engine-Wechsel ist der Tunnel der ALTEN Engine eine Leiche: er
# tunnelt weiter auf einen Port, an dem nichts (mehr) lauscht, und belegt dabei
# 3847 bzw. 9119 lokal. Beim Einrichten also gezielt entfernen.
remove_stale_second_macos() {
    local other label plist
    other=cockpit; [ "$SECOND_NAME" = "cockpit" ] && other=agent
    label="com.$(id -un).ssh-tunnel.ki-os-vm-${other}"
    plist="$HOME/Library/LaunchAgents/${label}.plist"
    if [ -f "$plist" ]; then
        launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
        rm -f "$plist"
        echo "OK: alter ${other}-Tunnel entfernt (Engine-Wechsel)"
    fi
}
remove_stale_second_linux() {
    local other unit
    other=cockpit; [ "$SECOND_NAME" = "cockpit" ] && other=agent
    unit="ki-os-vm-${other}-tunnel.service"
    if [ -f "$HOME/.config/systemd/user/${unit}" ]; then
        systemctl --user disable --now "${unit}" 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/${unit}"
        systemctl --user daemon-reload 2>/dev/null || true
        echo "OK: alter ${other}-Tunnel entfernt (Engine-Wechsel)"
    fi
}

if [ "$REMOVE" = "1" ]; then
    case "$(uname -s)" in
        Darwin) remove_macos_tunnels ;;
        Linux)  remove_linux_tunnels ;;
        *) echo "FAIL: nicht unterstuetztes OS ($(uname -s)) — fuer Windows setup-tunnels.ps1 -Remove nutzen." >&2; exit 1 ;;
    esac
    echo "OK: Tunnel-Autostarts abgebaut (Mutagen/SSH unangetastet)"
    exit 0
fi

[[ "$NOVNC_PORT"   =~ ^[0-9]+$ ]] || { echo "FAIL: --novnc-port fehlt/ungueltig" >&2; exit 2; }
if ! [[ "$SECOND_RPORT" =~ ^[0-9]+$ ]]; then
    if [ "$ENGINE" = "hermes" ]; then
        echo "FAIL: --agent-port fehlt/ungueltig (engine=hermes)" >&2
    else
        echo "FAIL: --cockpit-port fehlt/ungueltig" >&2
    fi
    exit 2
fi

SSH_OPTS="-o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=10 -o TCPKeepAlive=yes -o StrictHostKeyChecking=accept-new"

setup_macos_tunnel() {
    local name="$1" lport="$2" rport="$3"
    local label="com.$(id -un).ssh-tunnel.ki-os-vm-${name}"
    local plist="$HOME/Library/LaunchAgents/${label}.plist"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

    # launchd supervidiert einen nie endenden bash-Loop statt ssh direkt —
    # sonst parkt es den Job nach schnellen Fehlstarts (Sleep/Wake) dauerhaft.
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>while true; do /usr/bin/ssh -N ${SSH_OPTS} -L ${lport}:127.0.0.1:${rport} ki-os-vm; sleep 5; done</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>StandardOutPath</key><string>${HOME}/Library/Logs/ssh-tunnel-ki-os-vm-${name}.log</string>
    <key>StandardErrorPath</key><string>${HOME}/Library/Logs/ssh-tunnel-ki-os-vm-${name}.err.log</string>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST

    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    launchctl enable "gui/$(id -u)/${label}" 2>/dev/null || true
    echo "OK: LaunchAgent ${label} (lokal ${lport} -> VM ${rport})"
}

setup_linux_tunnel() {
    local name="$1" lport="$2" rport="$3"
    local unit="ki-os-vm-${name}-tunnel.service"
    mkdir -p "$HOME/.config/systemd/user"

    cat > "$HOME/.config/systemd/user/${unit}" <<UNIT
[Unit]
Description=SSH-Tunnel zur KI-OS-VM (${name}, ki-os-vm)
After=network-online.target
Wants=network-online.target
# Nie aufgeben: ohne dies parkt systemd die Unit nach einer Fehlstart-Serie
# (Netz beim Aufwachen noch nicht da) dauerhaft im failed-Zustand.
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/bin/ssh -N ${SSH_OPTS} -L ${lport}:127.0.0.1:${rport} ki-os-vm
Restart=always
RestartSec=15

[Install]
WantedBy=default.target
UNIT

    systemctl --user daemon-reload
    systemctl --user enable "${unit}" >/dev/null 2>&1 || true
    systemctl --user restart "${unit}"
    echo "OK: systemd-Unit ${unit} (lokal ${lport} -> VM ${rport})"
}

case "$(uname -s)" in
    Darwin)
        remove_stale_second_macos
        setup_macos_tunnel novnc 6080 "$NOVNC_PORT"
        setup_macos_tunnel "$SECOND_NAME" "$SECOND_LPORT" "$SECOND_RPORT"
        ;;
    Linux)
        remove_stale_second_linux
        setup_linux_tunnel novnc 6080 "$NOVNC_PORT"
        setup_linux_tunnel "$SECOND_NAME" "$SECOND_LPORT" "$SECOND_RPORT"
        # Linger: User-Services auch ohne aktive Login-Session
        # grep ohne -q (liest bis EOF): 'grep -q' beendet die Pipe frueh, loginctl
        # stirbt an SIGPIPE und unter pipefail wird ein Treffer zu "false" — dann
        # laeuft enable-linger unnoetig und meldet ggf. WARN, obwohl Linger steht.
        if ! loginctl show-user "$USER" 2>/dev/null | grep '^Linger=yes' >/dev/null; then
            sudo -n loginctl enable-linger "$USER" 2>/dev/null \
                || loginctl enable-linger "$USER" 2>/dev/null \
                || echo "WARN: Linger nicht aktiviert — bitte manuell: sudo loginctl enable-linger $USER"
        fi
        ;;
    *) echo "FAIL: nicht unterstuetztes OS ($(uname -s)) — fuer Windows setup-tunnels.ps1 nutzen." >&2; exit 1 ;;
esac

# --- Kurz-Verifikation --------------------------------------------------------
sleep 4
for pair in "6080:/vnc.html:noVNC" "${SECOND_LPORT}::${SECOND_LABEL}"; do
    port="${pair%%:*}"; rest="${pair#*:}"; path="${rest%%:*}"; label="${rest#*:}"
    code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${port}${path}" 2>/dev/null || true)"
    if [ "$code" = "200" ] || [ "${code:0:1}" = "3" ]; then
        echo "VERIFY_OK: ${label} erreichbar (localhost:${port}, HTTP ${code})"
    else
        echo "VERIFY_PENDING: ${label} (localhost:${port}) noch nicht erreichbar — Tunnel braucht ggf. ein paar Sekunden; sonst references/tunnels.md -> Troubleshooting."
    fi
done
