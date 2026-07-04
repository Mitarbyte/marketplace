#!/usr/bin/env bash
# =============================================================================
# register-desktop-app.sh — Claude-Code-Desktop-App vorkonfigurieren
# (macOS: ssh_configs.json + ~/.claude.json; Linux: nur ~/.claude.json)
#
# (a) SSH-Host ki-os-vm als gespeicherte Verbindung + Trusted-Host in der
#     Desktop-App-Konfiguration (ssh_configs.json) — nur macOS.
# (b) Remote-Workspace ssh:ki-os-vm:/home/<VM_USER>/KI-OS als vertrautes
#     Projekt in ~/.claude.json (kein Trust-Prompt).
#
# Hintergrund + manueller Fallback: references/desktop-app.md.
#
# Usage:  register-desktop-app.sh --vm-user <VM_USER>
# =============================================================================
set -euo pipefail

VM_USER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --vm-user) VM_USER="$2"; shift 2 ;;
        *) echo "FAIL: unbekanntes Argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$VM_USER" ] || { echo "FAIL: --vm-user fehlt" >&2; exit 2; }

python3 -c 'pass' 2>/dev/null || {
    echo "FAIL: python3 nicht nutzbar — auf macOS 'xcode-select --install' ausfuehren (kommt mit Homebrew normalerweise mit), dann wiederholen." >&2
    exit 1
}

# --- (a) ssh_configs.json (nur macOS — es gibt keine Linux-Desktop-App) --------
if [ "$(uname -s)" = "Darwin" ]; then
    APPDIR="$HOME/Library/Application Support/Claude"
    if [ ! -d "$APPDIR" ]; then
        echo "SKIP: Claude-Desktop-App nicht gefunden ($APPDIR) — claude.ai/code oder Terminal nutzen."
    else
        python3 - "$APPDIR/ssh_configs.json" <<'PY'
import json, os, sys, uuid
path = sys.argv[1]
data = {}
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
data.setdefault("configs", [])
data.setdefault("trustedHosts", [])
if not any(c.get("sshHost") == "ki-os-vm" for c in data["configs"]):
    data["configs"].append({"name": "ki-os-vm", "sshHost": "ki-os-vm",
                            "id": str(uuid.uuid4()), "source": "desktop"})
if "ki-os-vm" not in data["trustedHosts"]:
    data["trustedHosts"].append("ki-os-vm")
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
PY
        echo "OK: SSH-Host ki-os-vm in ssh_configs.json registriert."
        echo "HINWEIS: Desktop-App komplett beenden (Cmd+Q) und neu oeffnen — sie liest ssh_configs.json nur beim Start."
    fi
fi

# --- (b) ~/.claude.json Workspace-Eintrag ---------------------------------------
SETTINGS="$HOME/.claude.json"
KEY="ssh:ki-os-vm:/home/${VM_USER}/KI-OS"

if [ ! -f "$SETTINGS" ]; then
    echo "WARN: $SETTINGS fehlt — einmalig 'claude' lokal starten, dann diesen Schritt wiederholen (Skill-Re-Run ist idempotent)."
    exit 0
fi

python3 - "$SETTINGS" "$KEY" <<'PY'
import json, os, sys
path, key = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
projects = data.setdefault("projects", {})
entry = projects.setdefault(key, {})
entry.setdefault("allowedTools", [])
entry.setdefault("mcpContextUris", [])
entry.setdefault("enabledMcpjsonServers", [])
entry.setdefault("disabledMcpjsonServers", [])
entry["hasTrustDialogAccepted"] = True   # ohne dies wirft die App den Trust-Dialog
entry.setdefault("projectOnboardingSeenCount", 0)
entry.setdefault("hasClaudeMdExternalIncludesApproved", False)
entry.setdefault("hasClaudeMdExternalIncludesWarningShown", False)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
PY
echo "OK: ${KEY} in ~/.claude.json registriert (hasTrustDialogAccepted=true)."
