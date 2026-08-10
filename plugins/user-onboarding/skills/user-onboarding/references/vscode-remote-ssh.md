# VS Code Remote SSH (macOS / Windows / Linux)

Nicht Teil des Onboarding-Skills, aber häufig nachgefragt: VS Code als Editor
direkt auf der VM.

## Setup

1. VS Code installieren:
   - macOS: `brew install --cask visual-studio-code`
   - Windows: `winget install --id Microsoft.VisualStudioCode -e --accept-package-agreements --accept-source-agreements`
   - Linux: Paketquelle/Snap der Distribution
2. Extension **„Remote - SSH"** installieren
   (`code --install-extension ms-vscode-remote.remote-ssh`)
3. `Cmd/Ctrl+Shift+P` → **„Remote-SSH: Connect to Host"** → `ki-os-vm`
4. Beim ersten Mal installiert VS Code automatisch das VS-Code-Server-Bundle
   auf der VM (30–60 s)
5. Ordner öffnen: `~/KI-OS/` (z.B. `/home/alice/KI-OS`)
6. Terminal in VS Code öffnen → `claude`

## Tipps

- **Windows — OpenSSH-Pfad explizit setzen**, falls VS Code die falsche
  `ssh.exe` greift (z.B. die Git-Bash-Variante). Settings (`Ctrl+,`):
  ```json
  "remote.SSH.path": "C:\\Windows\\System32\\OpenSSH\\ssh.exe"
  ```
- **`.vscode/settings.json`** auf der VM:
  ```json
  {
    "terminal.integrated.defaultProfile.linux": "bash",
    "files.watcherExclude": {
      "**/node_modules/**": true,
      "**/.venv/**": true,
      "**/data/**": true
    }
  }
  ```
  Verhindert, dass VS Code große Verzeichnisse beobachtet (CPU-Spike).
- **Multi-Root Workspace** bei mehreren Projekten:
  `File → Save Workspace As…` → `<name>.code-workspace`
- **Extensions auf der VM** werden separat installiert (Sidebar zeigt
  „Local" vs. „Remote").

## Troubleshooting

| Symptom | Lösung |
|---------|---------|
| `Could not establish connection` | Erst per `ssh ki-os-vm` testen — wenn das nicht klappt, klappt auch Remote-SSH nicht |
| VS Code nutzt falsche `ssh.exe` (Windows) | `remote.SSH.path` explizit setzen (siehe oben) |
| VS-Code-Server-Install hängt | VM-Storage voll? `ssh ki-os-vm df -h ~` |
| Hoher CPU im VS-Code-Server-Prozess | `files.watcherExclude` setzen (siehe oben) |
| Re-Login bei jedem VS-Code-Start | Key per `ssh-add` in den ssh-agent laden (Windows: ssh-agent-Service starten, `references/ssh.md`) |
| `Bad owner or permissions` (Windows) | ACLs reparieren: `scripts/setup-ssh.ps1` erneut laufen lassen |
