# user-onboarding — Lokaler KI-OS-Onboarding-Skill

Claude-Code-Skill, den ein Mitarbeiter auf seinem lokalen Geraet
(Mac/Linux/Windows) installiert, um sich mit dem vom Admin angelegten
KI-OS-Workspace auf der Firmen-VM zu verbinden.

Workspaces, Browser und Logins leben auf der VM — lokal richten wir nur
den Zugriff ein: SSH-Key, minimale SSH-Config und drei
Pflicht-Autostarts (noVNC-Tunnel, Cockpit-Tunnel, Mutagen-Sync) plus den
Workspace-Eintrag fuer die Claude-Code-Desktop-App.

## Voraussetzungen

- macOS, Linux oder Windows
  - macOS / Linux: `ssh`, `curl` (Standard)
  - Windows nativ: PowerShell 5.1+, der Windows-OpenSSH-Client
    (vorinstalliert auf Windows 10/11; sonst installiert ihn der Skill)
    und Git for Windows (Pflicht — Claude Code braucht auf nativem
    Windows die Git Bash; der Skill installiert es bei Bedarf per
    winget). WSL2 bleibt als Alternative — die Wahl trifft der Skill
    in Schritt 1.
- Claude Code installiert (`https://claude.com/claude-code`)
- Vom Admin erhalten: VM-Public-IP, VM-Username

## Was passiert beim ersten Lauf

1. SSH-Key erstellen (falls nicht vorhanden) und Public Key in die
   Zwischenablage — du schickst ihn an den Admin
2. Minimalen `~/.ssh/config`-Eintrag fuer den festen SSH-Alias `ki-os-vm`
   anlegen (wird nicht abgefragt)
3. **Pause** — du wartest auf Admin-Bestaetigung, dass dein VM-User
   komplett eingerichtet ist
4. SSH-Verbindung testen + deine User-Werte holen (Cockpit-Port,
   noVNC-Port, noVNC-Passwort)
5. **Pflicht-Autostart 1:** gehaerteter SSH-Tunnel zum noVNC —
   der VM-Browser ist danach dauerhaft unter
   `http://localhost:6080/vnc.html?resize=scale` zu sehen (Logins + Agent-Browser live)
6. **Pflicht-Autostart 2:** gehaerteter SSH-Tunnel zum Cockpit —
   dauerhaft unter `http://localhost:3847`
7. **Pflicht-Autostart 3:** Mutagen-Sync — dein VM-Workspace als echter
   lokaler Ordner `~/KI-OS` (two-way, offline lesbar; dort auch den
   Obsidian-Vault oeffnen)
8. Claude-Code-Desktop-App vorkonfigurieren (macOS/Windows): SSH-Host
   `ki-os-vm` als gespeicherte Verbindung (`ssh_configs.json`) + Workspace-
   Eintrag in `~/.claude.json` — die App zeigt die VM direkt im
   Remote-Projekt-Switcher, ohne dass du SSH von Hand einrichten musst
9. Verifikation; bei Bestands-Usern zusaetzlich: Migration vom alten
   Setup (Chrome-Bridge, vm-oauth, SSHFS werden rueckstandsfrei entfernt)

Autostart-Backends pro OS: LaunchAgents (macOS), systemd-User-Services
(Linux), Scheduled Tasks (Windows). Skill ist idempotent — kann beliebig
oft ausgefuehrt werden, schon konfigurierte Komponenten werden
uebersprungen.

## Danach: so arbeitest du

- **Claude-Code-Desktop-App** (primaer): Remote-Projekt `ki-os-vm` /
  `KI-OS` waehlen
- **Browser:** `claude.ai/code` → eigene Remote-Session
- **Terminal:** `ssh ki-os-vm` → `cd ~/KI-OS && claude`
- **VS Code Remote-SSH** (Techniker): `references/<os>/vscode-remote-ssh.md`
- **Browser-Logins:** einmalig im noVNC-Tab
  (`http://localhost:6080/vnc.html?resize=scale`) in die Zielsysteme einloggen
- **Dateien/Obsidian:** lokaler Ordner `~/KI-OS`

## Quellen

- `SKILL.md` — Hauptlogik
- `references/macos/` — macOS-Detail-Anleitungen (SSH, noVNC-Tunnel,
  Cockpit-Tunnel, Mutagen, VS Code)
- `references/linux/` — Linux-Detail-Anleitungen (inkl. WSL2-Hinweise)
- `references/windows/` — Windows-Detail-Anleitungen (nativ per
  PowerShell + Windows-OpenSSH + Scheduled Tasks)
- `references/migration-v1.md` — Rueckbau des alten Setups
  (Chrome-Bridge, vm-oauth, SSHFS)
- `references/api-keys.md` — Beispiel-Liste der API-Keys + OAuth-Flows
- `references/ssh-pubkey-handoff.md` — Mail-/Slack-Vorlage fuer den
  Pubkey-Versand
