# VS Code Remote SSH (Windows)

Nicht Teil des Onboarding-Skills, aber haeufig nachgefragt. Diese Doku zeigt
dem User, wie er nach dem Onboarding VS Code als Editor auf die VM bringt.

## Setup

1. VS Code installieren:
   ```powershell
   winget install --id Microsoft.VisualStudioCode -e --accept-package-agreements --accept-source-agreements
   ```
2. Extension installieren: **"Remote - SSH"** (`ms-vscode-remote.remote-ssh`)
   ```powershell
   code --install-extension ms-vscode-remote.remote-ssh
   ```
3. In VS Code: `Ctrl+Shift+P` → **"Remote-SSH: Connect to Host"** → `ki-os-vm`
4. Beim ersten Mal installiert VS Code automatisch das VS-Code-Server-Bundle
   auf die VM. Dauert 30-60s.
5. Ordner oeffnen: `~/KI-OS/` (z.B. `/home/alice/KI-OS`)
6. Terminal in VS Code oeffnen (`` Ctrl+` ``) → `claude`

## Tipps

- **OpenSSH-Pfad explizit setzen**, falls VS Code die falsche `ssh.exe`
  greift (z.B. eine Git-Bash-OpenSSH statt des nativen Windows-OpenSSH).
  In den Settings (`Ctrl+,`):
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
  Verhindert dass VS Code grosse Verzeichnisse beobachtet (CPU-Spike).

- **Multi-Root Workspace** wenn du mehrere Hubs/Projekte hast:
  `File → Save Workspace As...` → `<name>.code-workspace`

- **Extensions auf der VM:** Werden separat installiert. Einige Extensions
  (UI-fokussiert wie Theme) bleiben lokal, der Rest installiert sich auf
  der Remote-Seite. Die Liste zeigt VS Code in der Sidebar als "Local"
  vs "Remote".

## Troubleshooting

| Symptom | Loesung |
|---------|---------|
| `Could not establish connection` | Erst per `ssh ki-os-vm` in PowerShell testen — wenn das nicht klappt, klappt auch Remote-SSH nicht |
| VS Code nutzt falsche `ssh.exe` | `remote.SSH.path` explizit setzen (siehe oben) |
| VS-Code-Server-Install haengt | VM-Storage voll? `ssh ki-os-vm df -h ~` |
| Hoher CPU im VS-Code-Server-Prozess | `files.watcherExclude` setzen (siehe oben) |
| Re-Login bei jedem VS-Code-Start | `ssh-agent`-Service starten + `ssh-add` einmalig (siehe `ssh-setup.md`) |
| `Bad owner or permissions on ...config` | ACLs reparieren (siehe `ssh-setup.md`) |
