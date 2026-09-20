#!/usr/bin/env bash
# setup-tunnels.sh — beide gehaerteten SSH-Tunnel-Autostarts (macOS/Linux)
#
#   noVNC:   lokal 6080 -> VM 127.0.0.1:<NOVNC_PORT>
#   Agenten-Tunnel je Stack (docs/betrieb/vm-management.md § 8, ADR 18):
#     Claude-Stack (engine claude|hybrid)  Cockpit:       lokal 3847 -> VM 127.0.0.1:<COCKPIT_PORT>
#     Hermes-Stack (engine hermes|hybrid)  Hermes-Agent:  lokal 9119 -> VM 127.0.0.1:<AGENT_PORT>
#     Hermes-Stack (engine hermes|hybrid)  Artefakte:     lokal 29000 -> VM 127.0.0.1:<ARTIFACTS_PORT>
#       (Artefakt-Dienst ki-os-artifacts@<user>, ADR 22 Nr. 5 — das Plugin nennt
#        im tunnel-Modus http://localhost:29000/a/<slug>/; auf claude liefert der
#        Cockpit-Proxy 3847/a/, dort braucht es keinen eigenen Tunnel — B-215)
#   hybrid richtet also VIER Tunnel ein; der Tunnel eines nicht vorhandenen
#   Stacks wird als Leiche abgeraeumt (Engine-Wechsel).
#   Lokal 9119 ist bewusst der Hermes-Default: die Desktop-App schlaegt
#   127.0.0.1:9119 von selbst vor, der Mitarbeiter muss nichts umtippen.
#
# Backends: LaunchAgents (macOS, bash-Loop gegen launchd-Parken) bzw.
# systemd-User-Services (Linux, StartLimitIntervalSec=0). Idempotent —
# bestehende Instanzen werden neu geladen statt dupliziert. Haertungs-
# Begruendung: references/tunnels.md.
#
# Usage:  setup-tunnels.sh --novnc-port <VM_PORT> --cockpit-port <VM_PORT>
#         setup-tunnels.sh --novnc-port <VM_PORT> --agent-port <VM_PORT> --artifacts-port <VM_PORT> --engine hermes
#         setup-tunnels.sh --novnc-port <VM_PORT> --cockpit-port <VM_PORT> --agent-port <VM_PORT> --artifacts-port <VM_PORT> --engine hybrid
#         setup-tunnels.sh --remove
#
# --remove baut beide Tunnel-Autostarts idempotent ab (gateway-Modus: die VM
# stellt noVNC/Cockpit oeffentlich hinter Caddy+Kunden-IdP bereit, lokale
# Tunnel sind obsolet). Mutagen/SSH bleiben unangetastet.
set -euo pipefail

NOVNC_PORT="" COCKPIT_PORT="" AGENT_PORT="" ARTIFACTS_PORT="" ENGINE="claude" REMOVE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --novnc-port)     NOVNC_PORT="$2"; shift 2 ;;
        --cockpit-port)   COCKPIT_PORT="$2"; shift 2 ;;
        --agent-port)     AGENT_PORT="$2"; shift 2 ;;
        --artifacts-port) ARTIFACTS_PORT="$2"; shift 2 ;;
        --engine)       ENGINE="$2"; shift 2 ;;
        --remove)       REMOVE=1; shift ;;
        *) echo "FAIL: unbekanntes Argument: $1" >&2; exit 2 ;;
    esac
done
case "$ENGINE" in claude|hybrid|hermes) ;; *) echo "FAIL: --engine erlaubt nur claude|hybrid|hermes" >&2; exit 2 ;; esac

# Agenten-Tunnel nach Stack: WANT_COCKPIT (Claude-Stack) und WANT_AGENT +
# WANT_ARTIFACTS (Hermes-Stack) — hybrid hat alle. Alles Weitere (Backends,
# Haertung, --remove) ist identisch.
WANT_COCKPIT=0; WANT_AGENT=0; WANT_ARTIFACTS=0
case "$ENGINE" in claude|hybrid) WANT_COCKPIT=1 ;; esac
case "$ENGINE" in hermes|hybrid) WANT_AGENT=1; WANT_ARTIFACTS=1 ;; esac

remove_macos_tunnels() {
    local name label plist
    # BEIDE moeglichen Zweit-Tunnel abraeumen, nicht nur den der aktuellen
    # Engine: nach einem Engine-Wechsel liegt der andere sonst als Leiche herum
    # und tunnelt auf einen Port, an dem nichts mehr lauscht.
    for name in novnc cockpit agent artifacts; do
        label="com.$(id -un).ssh-tunnel.ki-os-vm-${name}"
        plist="$HOME/Library/LaunchAgents/${label}.plist"
        launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
        [ -f "$plist" ] && rm -f "$plist" && echo "OK: LaunchAgent ${label} entfernt" \
            || echo "OK: LaunchAgent ${label} war nicht vorhanden"
    done
}

remove_linux_tunnels() {
    local name unit
    for name in novnc cockpit agent artifacts; do
        unit="ki-os-vm-${name}-tunnel.service"
        systemctl --user disable --now "${unit}" 2>/dev/null || true
        [ -f "$HOME/.config/systemd/user/${unit}" ] \
            && rm -f "$HOME/.config/systemd/user/${unit}" && echo "OK: Unit ${unit} entfernt" \
            || echo "OK: Unit ${unit} war nicht vorhanden"
    done
    systemctl --user daemon-reload 2>/dev/null || true
}

# Nach einem Engine-Wechsel ist der Tunnel eines nicht mehr vorhandenen Stacks
# eine Leiche: er tunnelt weiter auf einen Port, an dem nichts (mehr) lauscht,
# und belegt dabei 3847 bzw. 9119 lokal. Beim Einrichten also gezielt entfernen.
stale_names() {   # Tunnel-Namen, die diese Engine NICHT hat
    [ "$WANT_COCKPIT" = "1" ]   || echo cockpit
    [ "$WANT_AGENT" = "1" ]     || echo agent
    [ "$WANT_ARTIFACTS" = "1" ] || echo artifacts
}
remove_stale_second_macos() {
    local other label plist
    for other in $(stale_names); do
        label="com.$(id -un).ssh-tunnel.ki-os-vm-${other}"
        plist="$HOME/Library/LaunchAgents/${label}.plist"
        if [ -f "$plist" ]; then
            launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
            rm -f "$plist"
            echo "OK: alter ${other}-Tunnel entfernt (Engine-Wechsel)"
        fi
    done
}
remove_stale_second_linux() {
    local other unit
    for other in $(stale_names); do
        unit="ki-os-vm-${other}-tunnel.service"
        if [ -f "$HOME/.config/systemd/user/${unit}" ]; then
            systemctl --user disable --now "${unit}" 2>/dev/null || true
            rm -f "$HOME/.config/systemd/user/${unit}"
            systemctl --user daemon-reload 2>/dev/null || true
            echo "OK: alter ${other}-Tunnel entfernt (Engine-Wechsel)"
        fi
    done
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
if [ "$WANT_COCKPIT" = "1" ] && ! [[ "$COCKPIT_PORT" =~ ^[0-9]+$ ]]; then
    echo "FAIL: --cockpit-port fehlt/ungueltig (engine=${ENGINE} hat den Claude-Stack)" >&2; exit 2
fi
if [ "$WANT_AGENT" = "1" ] && ! [[ "$AGENT_PORT" =~ ^[0-9]+$ ]]; then
    echo "FAIL: --agent-port fehlt/ungueltig (engine=${ENGINE} hat den Hermes-Stack)" >&2; exit 2
fi
if [ "$WANT_ARTIFACTS" = "1" ] && ! [[ "$ARTIFACTS_PORT" =~ ^[0-9]+$ ]]; then
    echo "FAIL: --artifacts-port fehlt/ungueltig (engine=${ENGINE} hat den Hermes-Stack; Wert ARTIFACTS_PORT aus get-vm-values)" >&2; exit 2
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
        [ "$WANT_COCKPIT" = "1" ]   && setup_macos_tunnel cockpit   3847  "$COCKPIT_PORT"
        [ "$WANT_AGENT" = "1" ]     && setup_macos_tunnel agent     9119  "$AGENT_PORT"
        [ "$WANT_ARTIFACTS" = "1" ] && setup_macos_tunnel artifacts 29000 "$ARTIFACTS_PORT"
        ;;
    Linux)
        remove_stale_second_linux
        setup_linux_tunnel novnc 6080 "$NOVNC_PORT"
        [ "$WANT_COCKPIT" = "1" ]   && setup_linux_tunnel cockpit   3847  "$COCKPIT_PORT"
        [ "$WANT_AGENT" = "1" ]     && setup_linux_tunnel agent     9119  "$AGENT_PORT"
        [ "$WANT_ARTIFACTS" = "1" ] && setup_linux_tunnel artifacts 29000 "$ARTIFACTS_PORT"
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
sleep "${KI_OS_TUNNEL_VERIFY_WAIT:-4}"
# Paar = port:pfad:label[:extra_ok] — der Artefakt-Dienst hat keine Wurzelseite
# (404 unter /a/ heisst: Dienst antwortet, Tunnel steht).
VERIFY_PAIRS="6080:/vnc.html:noVNC"
[ "$WANT_COCKPIT" = "1" ]   && VERIFY_PAIRS="${VERIFY_PAIRS} 3847::Cockpit"
[ "$WANT_AGENT" = "1" ]     && VERIFY_PAIRS="${VERIFY_PAIRS} 9119::Hermes-Dashboard"
[ "$WANT_ARTIFACTS" = "1" ] && VERIFY_PAIRS="${VERIFY_PAIRS} 29000:/a/:Artefakte:404"
for pair in ${VERIFY_PAIRS}; do
    port="${pair%%:*}"; rest="${pair#*:}"; path="${rest%%:*}"; rest="${rest#*:}"; label="${rest%%:*}"
    extra_ok=""; case "$rest" in *:*) extra_ok="${rest#*:}" ;; esac
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:${port}${path}" 2>/dev/null || true)"
    if [ "$code" = "200" ] || [ "${code:0:1}" = "3" ] || { [ -n "$extra_ok" ] && [ "$code" = "$extra_ok" ]; }; then
        echo "VERIFY_OK: ${label} erreichbar (localhost:${port}, HTTP ${code})"
    else
        echo "VERIFY_PENDING: ${label} (localhost:${port}) noch nicht erreichbar — Tunnel braucht ggf. ein paar Sekunden; sonst references/tunnels.md -> Troubleshooting."
    fi
done
