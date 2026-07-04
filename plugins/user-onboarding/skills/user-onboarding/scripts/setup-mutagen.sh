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
            brew install mutagen-io/mutagen/mutagen
            ;;
        Linux)
            if command -v brew >/dev/null 2>&1; then
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

"$MUTAGEN_BIN" sync list ki-os || true
