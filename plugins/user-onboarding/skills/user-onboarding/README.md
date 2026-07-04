# user-onboarding — Lokaler KI-OS-Onboarding-Skill

Claude-Code-Skill, den ein Mitarbeiter auf seinem lokalen Gerät
(Mac/Linux/Windows) installiert, um sich mit dem vom Admin angelegten
KI-OS-Workspace auf der Firmen-VM zu verbinden.

Workspaces, Browser und Logins leben auf der VM — lokal richten wir nur den
Zugriff ein: SSH-Key, minimale SSH-Config und drei Pflicht-Autostarts
(noVNC-Tunnel, Cockpit-Tunnel, Mutagen-Sync) plus die Vorkonfiguration der
Claude-Code-Desktop-App. Die gesamte Mechanik liegt in fertigen,
parametrisierten Skripten unter `scripts/` (bash für macOS/Linux, PowerShell
für natives Windows) — der Skill orchestriert nur noch.

## Voraussetzungen

- macOS, Linux oder Windows
  - macOS / Linux: `ssh`, `curl` (Standard); macOS zusätzlich Homebrew
    (für Mutagen)
  - Windows nativ: PowerShell 5.1+, Windows-OpenSSH-Client (vorinstalliert
    auf Windows 10/11; sonst installiert ihn `scripts/check-prereqs.ps1`,
    braucht Admin) und Git for Windows (Pflicht — Claude Code braucht auf
    nativem Windows die Git Bash). WSL2 bleibt als Alternative.
- Claude Code installiert (`https://claude.com/claude-code`)
- Vom Admin erhalten: VM-Public-IP, VM-Username

## Was passiert beim ersten Lauf

1. SSH-Key erstellen (falls nicht vorhanden) + minimalen
   `~/.ssh/config`-Eintrag für den festen Alias `ki-os-vm` schreiben —
   Public Key geht in die Zwischenablage, du schickst ihn an den Admin
2. **Pause** — warten auf Admin-Bestätigung, dass dein VM-User komplett
   eingerichtet ist
3. SSH-Smoketest + deine User-Werte holen (ein Roundtrip: Cockpit-Port,
   noVNC-Port, noVNC-Passwort)
4. **Pflicht-Autostart 1+2:** gehärtete SSH-Tunnel zu noVNC
   (`http://localhost:6080/vnc.html?resize=scale`) und Cockpit
   (`http://localhost:3847`)
5. **Pflicht-Autostart 3:** Mutagen-Sync — dein VM-Workspace als echter
   lokaler Ordner `~/KI-OS` (two-way, offline lesbar; dort auch den
   Obsidian-Vault öffnen)
6. Claude-Code-Desktop-App vorkonfigurieren (macOS/Windows): SSH-Host
   `ki-os-vm` + vertrauter Workspace — die VM erscheint direkt im
   Remote-Projekt-Switcher
7. Verifikation aller Komponenten

Autostart-Backends pro OS: LaunchAgents (macOS), systemd-User-Services
(Linux), Scheduled Tasks (Windows). Der Skill ist idempotent — ein erneuter
Lauf ist das Update.

## Danach: so arbeitest du

- **Claude-Code-Desktop-App** (primär): Remote-Projekt `ki-os-vm` / `KI-OS`
- **Browser:** `claude.ai/code` → eigene Remote-Session
- **Terminal:** `ssh ki-os-vm` → `cd ~/KI-OS && claude`
- **VS Code Remote-SSH** (Techniker): `references/vscode-remote-ssh.md`
- **Browser-Logins:** einmalig im noVNC-Tab in die Zielsysteme einloggen
- **Dateien/Obsidian:** lokaler Ordner `~/KI-OS`

## Quellen

- `SKILL.md` — Orchestrierung (Schritte, Inputs, Skript-Aufrufe)
- `scripts/` — parametrisierte Setup-Skripte (`.sh` = macOS/Linux,
  `.ps1` = natives Windows): `check-prereqs.ps1`, `setup-ssh`,
  `get-vm-values`, `setup-tunnels`, `setup-mutagen`,
  `register-desktop-app`, `verify`
- `references/tunnels.md` — Tunnel-Härtung (Warum) + Troubleshooting
- `references/mutagen.md` — Sync-Semantik, Ignores, Troubleshooting
- `references/ssh.md` — SSH-Details (BOM/ACL/Passphrase) + Fehlerbilder
- `references/desktop-app.md` — Desktop-App-Vorkonfiguration
- `references/vscode-remote-ssh.md` — VS Code Remote-SSH
- `references/ssh-pubkey-handoff.md` — Mail-/Slack-Vorlage für den Pubkey
- `references/api-keys.md` — Claude-Login/Token-Setup auf der VM
