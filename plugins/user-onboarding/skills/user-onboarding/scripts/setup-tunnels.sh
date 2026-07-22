#!/usr/bin/env bash
# =============================================================================
# setup-tunnels.sh — beide gehaerteten SSH-Tunnel-Autostarts (macOS/Linux)
#
#   noVNC:   lokal 6080 -> VM 127.0.0.1:<NOVNC_PORT>
#   Cockpit: lokal 3847 -> VM 127.0.0.1:<COCKPIT_PORT>
#
# Backends: LaunchAgents (macOS, bash-Loop gegen launchd-Parken) bzw.
# systemd-User-Services (Linux, StartLimitIntervalSec=0). Idempotent —
# bestehende Instanzen werden neu geladen statt dupliziert. Haertungs-
# Begruendung: references/tunnels.md.
#
# Usage:  setup-tunnels.sh --novnc-port <VM_PORT> --cockpit-port <VM_PORT>
#         setup-tunnels.sh --remove
#
# --remove baut beide Tunnel-Autostarts idempotent ab (gateway-Modus: die VM
# stellt noVNC/Cockpit oeffentlich hinter Caddy+Kunden-IdP bereit, lokale
# Tunnel sind obsolet). Mutagen/SSH bleiben unangetastet.
# =============================================================================
set -euo pipefail

NOVNC_PORT="" COCKPIT_PORT="" REMOVE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --novnc-port)   NOVNC_PORT="$2"; shift 2 ;;
        --cockpit-port) COCKPIT_PORT="$2"; shift 2 ;;
        --remove)       REMOVE=1; shift ;;
        *) echo "FAIL: unbekanntes Argument: $1" >&2; exit 2 ;;
    esac
done

remove_macos_tunnels() {
    local name label plist
    for name in novnc cockpit; do
        label="com.$(id -un).ssh-tunnel.ki-os-vm-${name}"
        plist="$HOME/Library/LaunchAgents/${label}.plist"
        launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
        [ -f "$plist" ] && rm -f "$plist" && echo "OK: LaunchAgent ${label} entfernt" \
            || echo "OK: LaunchAgent ${label} war nicht vorhanden"
    done
}

remove_linux_tunnels() {
    local name unit
    for name in novnc cockpit; do
        unit="ki-os-vm-${name}-tunnel.service"
        systemctl --user disable --now "${unit}" 2>/dev/null || true
        [ -f "$HOME/.config/systemd/user/${unit}" ] \
            && rm -f "$HOME/.config/systemd/user/${unit}" && echo "OK: Unit ${unit} entfernt" \
            || echo "OK: Unit ${unit} war nicht vorhanden"
    done
    systemctl --user daemon-reload 2>/dev/null || true
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
[[ "$COCKPIT_PORT" =~ ^[0-9]+$ ]] || { echo "FAIL: --cockpit-port fehlt/ungueltig" >&2; exit 2; }

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
        setup_macos_tunnel novnc   6080 "$NOVNC_PORT"
        setup_macos_tunnel cockpit 3847 "$COCKPIT_PORT"
        ;;
    Linux)
        setup_linux_tunnel novnc   6080 "$NOVNC_PORT"
        setup_linux_tunnel cockpit 3847 "$COCKPIT_PORT"
        # Linger: User-Services auch ohne aktive Login-Session
        if ! loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes'; then
            sudo -n loginctl enable-linger "$USER" 2>/dev/null \
                || loginctl enable-linger "$USER" 2>/dev/null \
                || echo "WARN: Linger nicht aktiviert — bitte manuell: sudo loginctl enable-linger $USER"
        fi
        ;;
    *) echo "FAIL: nicht unterstuetztes OS ($(uname -s)) — fuer Windows setup-tunnels.ps1 nutzen." >&2; exit 1 ;;
esac

# --- Kurz-Verifikation --------------------------------------------------------
sleep 4
for pair in "6080:/vnc.html:noVNC" "3847::Cockpit"; do
    port="${pair%%:*}"; rest="${pair#*:}"; path="${rest%%:*}"; label="${rest#*:}"
    code="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${port}${path}" 2>/dev/null || true)"
    if [ "$code" = "200" ] || [ "${code:0:1}" = "3" ]; then
        echo "VERIFY_OK: ${label} erreichbar (localhost:${port}, HTTP ${code})"
    else
        echo "VERIFY_PENDING: ${label} (localhost:${port}) noch nicht erreichbar — Tunnel braucht ggf. ein paar Sekunden; sonst references/tunnels.md -> Troubleshooting."
    fi
done
