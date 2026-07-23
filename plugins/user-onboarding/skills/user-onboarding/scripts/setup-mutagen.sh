#!/usr/bin/env bash
# =============================================================================
# setup-mutagen.sh — Mutagen installieren + Daemon-Autostart + Session ki-os
# (macOS/Linux)
#
#   VM (Alpha, gewinnt Konflikte):  ki-os-vm:/home/<VM_USER>/KI-OS
#   Lokal (Beta):                   ~/KI-OS
#
# Ignore-Begruendung + Konflikt-Semantik: references/mutagen.md.
#
# Usage:  setup-mutagen.sh --vm-user <VM_USER> [--recreate]
#
# Output-Marker: SESSION_EXISTS | SESSION_CREATED | SESSION_RECREATED
# =============================================================================
set -euo pipefail

VM_USER="" RECREATE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --vm-user)  VM_USER="$2"; shift 2 ;;
        --recreate) RECREATE=1; shift ;;
        *) echo "FAIL: unbekanntes Argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$VM_USER" ] || { echo "FAIL: --vm-user fehlt" >&2; exit 2; }

OS="$(uname -s)"

# --- 1. Installieren ----------------------------------------------------------
if ! command -v mutagen >/dev/null 2>&1; then
    case "$OS" in
        Darwin)
            command -v brew >/dev/null 2>&1 || {
                echo "FAIL: Homebrew fehlt — erst https://brew.sh folgen, dann diesen Schritt wiederholen." >&2
                exit 1
            }
            # Homebrews "trusted tap"-Gate (neuere brew-Versionen) blockiert sonst
            # den Install, weil der Tap auch mutagen-beta enthaelt. No-op auf
            # aelteren brew ohne 'trust'-Subcommand.
            brew trust mutagen-io/mutagen >/dev/null 2>&1 || true
            brew install mutagen-io/mutagen/mutagen
            ;;
        Linux)
            if command -v brew >/dev/null 2>&1; then
                brew trust mutagen-io/mutagen >/dev/null 2>&1 || true
                brew install mutagen-io/mutagen/mutagen
            else
                mkdir -p "$HOME/.local/bin"
                case "$(uname -m)" in
                    aarch64|arm64) ARCH=linux_arm64 ;;
                    *)             ARCH=linux_amd64 ;;
                esac
                URL="$(curl -fsSL https://api.github.com/repos/mutagen-io/mutagen/releases/latest \
                    | grep -o "\"browser_download_url\": *\"[^\"]*${ARCH}[^\"]*\"" \
                    | grep -o 'https[^"]*' | grep -v sidecar | head -1)"
                [ -n "$URL" ] || { echo "FAIL: Mutagen-Release-URL nicht gefunden." >&2; exit 1; }
                curl -fsSL "$URL" | tar -xz -C "$HOME/.local/bin" mutagen
                chmod +x "$HOME/.local/bin/mutagen"
                export PATH="$HOME/.local/bin:$PATH"
            fi
            ;;
    esac
fi
MUTAGEN_BIN="$(command -v mutagen)"
echo "OK: mutagen $("$MUTAGEN_BIN" version 2>/dev/null | head -1) (${MUTAGEN_BIN})"

# --- 2. Daemon-Autostart --------------------------------------------------------
if [ "$OS" = "Darwin" ]; then
    "$MUTAGEN_BIN" daemon register >/dev/null 2>&1 || true   # offizielle launchd-Integration
    "$MUTAGEN_BIN" daemon start   >/dev/null 2>&1 || true
    echo "OK: Daemon-Autostart (launchd, mutagen daemon register)"
else
    # 'daemon register' unterstuetzt Linux nicht -> systemd-User-Service
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/mutagen-daemon.service" <<UNIT
[Unit]
Description=Mutagen-Daemon (Sync-Sessions)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MUTAGEN_BIN} daemon run
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
UNIT
    "$MUTAGEN_BIN" daemon stop >/dev/null 2>&1 || true   # CLI-gestarteten Daemon abloesen
    systemctl --user daemon-reload
    systemctl --user enable --now mutagen-daemon.service
    # Linger, damit Daemon + Watchdog-Timer NICHT beim Logout stoppen und erst
    # beim naechsten Login wieder anlaufen. Im tunnel-Modus setzt das
    # setup-tunnels.sh; im gateway-Modus laeuft der aber nicht -> hier absichern
    # (idempotent, eigener User braucht i.d.R. kein root).
    loginctl enable-linger "$(id -un)" >/dev/null 2>&1 \
        || echo "WARN: loginctl enable-linger fehlgeschlagen — Sync stoppt evtl. beim Logout (einmalig: sudo loginctl enable-linger $(id -un))"
    echo "OK: Daemon-Autostart (systemd-User-Service mutagen-daemon.service)"
fi

# --- 3. Session ki-os ----------------------------------------------------------
create_session() {
    # VM ist Alpha (gewinnt bei Konflikten), lokal ist Beta. .claude/skills wird
    # auf macOS/Linux bewusst mitgesynct (relative Skill-Symlinks -> klickbare
    # Skill-Ansicht); Details: references/mutagen.md.
    "$MUTAGEN_BIN" sync create \
        --name=ki-os \
        --sync-mode=two-way-resolved \
        --ignore-vcs \
        --ignore="node_modules" \
        --ignore=".venv" \
        --ignore="__pycache__" \
        --ignore=".obsidian/workspace*" \
        --ignore=".cache" \
        --ignore="dist" \
        --ignore=".next" \
        --ignore=".DS_Store" \
        "ki-os-vm:/home/${VM_USER}/KI-OS" "$HOME/KI-OS"
}

if "$MUTAGEN_BIN" sync list ki-os >/dev/null 2>&1; then
    if [ "$RECREATE" -eq 1 ]; then
        "$MUTAGEN_BIN" sync terminate ki-os
        create_session
        echo "SESSION_RECREATED: ki-os neu angelegt (Dateien bleiben erhalten)."
    else
        echo "SESSION_EXISTS: ki-os laeuft bereits — bei abweichender Konfiguration mit --recreate neu anlegen."
    fi
else
    create_session
    echo "SESSION_CREATED: ki-os (VM:/home/${VM_USER}/KI-OS <-> ~/KI-OS)"
fi

# --- 4. Session-Watchdog (Selbstheilung: resume bei paused/halted) ------------
# Der Daemon-Autostart aus Schritt 2 haelt nur den *Prozess* am Leben. Eine
# Session, die nach langem VM-Idle-Suspend in paused/halted laeuft, heilt sich
# NICHT von selbst (Mutagens Eigen-Reconnect greift nur bei transienten
# Transport-Abrissen) — VM-seitig erscheint dann ein toter mutagen-agent und
# lokale Skill-Outputs kommen nicht mehr an. Ein kleiner 2-Min-Guard resumt sie.
# Windows deckt dasselbe ueber ki-os-vm-watchdog ab (setup-tunnels.ps1).
GUARD="$HOME/.local/bin/ki-os-mutagen-watchdog.sh"
mkdir -p "$HOME/.local/bin"
cat > "$GUARD" <<'GUARD_EOF'
#!/usr/bin/env bash
# ki-os-mutagen-watchdog.sh — generiert von setup-mutagen.sh.
# Haelt Mutagen-Daemon + Session 'ki-os' selbstheilend; laeuft alle ~2 min
# (launchd StartInterval / systemd-Timer).
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
command -v mutagen >/dev/null 2>&1 || exit 0
mutagen daemon start >/dev/null 2>&1 || true   # no-op wenn Daemon laeuft
info="$(mutagen sync list ki-os 2>/dev/null)" || exit 0
# Session gar nicht vorhanden -> nicht hier neu anlegen (braucht den VM-Pfad);
# das ist ein Setup-Fall -> /user-onboarding erneut laufen lassen.
[ -n "$info" ] || exit 0
# Steady-State 'Watching for changes' = gesund -> nichts tun. Jeder andere
# Zustand (Paused/Halted/abgerissen) -> resume. resume ist idempotent (no-op
# auf laufender/scannender Session), heilt aber paused/halted.
printf '%s\n' "$info" | grep -q 'Watching for changes' \
    || mutagen sync resume ki-os >/dev/null 2>&1 || true
GUARD_EOF
chmod +x "$GUARD"

if [ "$OS" = "Darwin" ]; then
    WD_LABEL="com.$(id -un).ki-os-vm.mutagen-watchdog"
    WD_PLIST="$HOME/Library/LaunchAgents/${WD_LABEL}.plist"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    cat > "$WD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${WD_LABEL}</string>
    <key>ProgramArguments</key>
    <array><string>/bin/bash</string><string>${GUARD}</string></array>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>120</integer>
    <key>StandardOutPath</key><string>${HOME}/Library/Logs/ki-os-mutagen-watchdog.log</string>
    <key>StandardErrorPath</key><string>${HOME}/Library/Logs/ki-os-mutagen-watchdog.err.log</string>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)/${WD_LABEL}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$WD_PLIST"
    launchctl enable "gui/$(id -u)/${WD_LABEL}" 2>/dev/null || true
    echo "OK: Session-Watchdog (LaunchAgent ${WD_LABEL}, alle 120s)"
else
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/ki-os-mutagen-watchdog.service" <<UNIT
[Unit]
Description=KI-OS Mutagen-Session-Watchdog (resume bei paused/halted)

[Service]
Type=oneshot
ExecStart=/bin/bash ${GUARD}
UNIT
    cat > "$HOME/.config/systemd/user/ki-os-mutagen-watchdog.timer" <<UNIT
[Unit]
Description=KI-OS Mutagen-Session-Watchdog alle 2 Minuten

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now ki-os-mutagen-watchdog.timer
    echo "OK: Session-Watchdog (systemd-Timer ki-os-mutagen-watchdog.timer, alle 2 min)"
fi

"$MUTAGEN_BIN" sync list ki-os || true
