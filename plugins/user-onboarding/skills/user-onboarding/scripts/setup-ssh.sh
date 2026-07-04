#!/usr/bin/env bash
# =============================================================================
# setup-ssh.sh — SSH-Key + minimaler ~/.ssh/config-Eintrag (macOS/Linux)
#
# Erzeugt (falls noetig) den Ed25519-Key, ersetzt den Host-Block `ki-os-vm`
# in ~/.ssh/config idempotent durch die minimale Fassung und legt den
# Public Key in die Zwischenablage.
#
# Usage:
#   setup-ssh.sh --ip <VM_IP> --user <VM_USER> [--email <EMAIL>] [--new-key]
#
# Output-Marker (fuer den orchestrierenden Skill):
#   KEY_EXISTS | KEY_CREATED, CONFIG_WRITTEN, PUBKEY: <key>
# =============================================================================
set -euo pipefail

VM_IP="" VM_USER="" EMAIL="" NEW_KEY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --ip)      VM_IP="$2"; shift 2 ;;
        --user)    VM_USER="$2"; shift 2 ;;
        --email)   EMAIL="$2"; shift 2 ;;
        --new-key) NEW_KEY=1; shift ;;
        *) echo "FAIL: unbekanntes Argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$VM_IP" ]   || { echo "FAIL: --ip fehlt" >&2; exit 2; }
[ -n "$VM_USER" ] || { echo "FAIL: --user fehlt" >&2; exit 2; }

KEY="$HOME/.ssh/id_ed25519"
CFG="$HOME/.ssh/config"

mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
touch "$CFG"; chmod 600 "$CFG"

# --- SSH-Key ---------------------------------------------------------------
if [ -f "$KEY" ] && [ "$NEW_KEY" -eq 0 ]; then
    echo "KEY_EXISTS: $KEY wird verwendet."
else
    if [ -f "$KEY" ]; then
        echo "FAIL: $KEY existiert bereits — --new-key wuerde ihn ueberschreiben. Erst manuell wegsichern/loeschen." >&2
        exit 1
    fi
    if [ -n "$EMAIL" ]; then
        ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEY" -N "" >/dev/null
    else
        ssh-keygen -t ed25519 -f "$KEY" -N "" >/dev/null
    fi
    echo "KEY_CREATED: $KEY (Ed25519, ohne Passphrase — nachtraeglich per 'ssh-keygen -p' setzbar)."
fi

# --- Host-Block ersetzen (idempotent) ---------------------------------------
# Bestehende ki-os-vm-Bloecke (inkl. Altlasten wie ki-os-vm-mux) entfernen,
# dann die minimale Fassung anhaengen. Bewusst KEIN ControlMaster, KEINE
# LocalForward-/RemoteForward-Zeilen — die Tunnel laufen als eigene
# Autostart-Prozesse mit -L (siehe setup-tunnels.sh).
TMP="$(mktemp)"
awk '
    /^[Hh]ost[ \t]/ { skip = ($2 == "ki-os-vm" || $2 == "ki-os-vm-mux") ? 1 : 0 }
    skip == 0 { print }
' "$CFG" > "$TMP"

# Trailing-Leerzeilen normalisieren, dann Block anhaengen
printf '%s\n' "$(cat "$TMP")" > "$CFG" 2>/dev/null || : > "$CFG"
rm -f "$TMP"
[ -s "$CFG" ] && echo >> "$CFG"

cat >> "$CFG" <<EOF
Host ki-os-vm
    HostName ${VM_IP}
    User ${VM_USER}
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 15
    ServerAliveCountMax 3
    ConnectTimeout 10
    TCPKeepAlive yes
EOF
chmod 600 "$CFG"
echo "CONFIG_WRITTEN: Host ki-os-vm -> ${VM_USER}@${VM_IP} ($CFG)"

# --- Public Key in die Zwischenablage + ausgeben -----------------------------
PUB="$(cat "${KEY}.pub")"
if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$PUB" | pbcopy && echo "CLIPBOARD: Public Key kopiert (pbcopy)."
elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$PUB" | xclip -selection clipboard && echo "CLIPBOARD: Public Key kopiert (xclip)."
elif command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$PUB" | wl-copy && echo "CLIPBOARD: Public Key kopiert (wl-copy)."
else
    echo "CLIPBOARD: keine Clipboard-CLI gefunden — Key unten manuell kopieren."
fi
echo "PUBKEY: $PUB"
