# user-onboarding — Lokaler KI-OS-Onboarding-Skill

Claude-Code-Skill, den ein Mitarbeiter auf seinem lokalen Gerät
(Mac/Linux/Windows) installiert, um sich mit dem vom Admin angelegten
KI-OS-Workspace auf der Firmen-VM zu verbinden.

Workspaces, Browser und Logins leben auf der VM — lokal wird nur der Zugriff
eingerichtet. **Der Skill fragt als erstes den Zugangs-Modus ab** und fährt
dann genau einen von zwei Pfaden:

| | **gateway** (Regelfall) | **tunnel** |
|---|---|---|
| Woran erkennbar | Admin schickte eine **URL** (`https://<name>-cockpit.…` / `…-agent.…`) + Firmen-Login | Admin schickte nur **IP + Username** |
| SSH-Key | trägst du **selbst im Cockpit** ein (Tab System → „SSH-Zugang") | geht **an den Admin** |
| Tunnel | entfallen — noVNC/Cockpit laufen über die Gateway-URLs | noVNC (`localhost:6080`) + Cockpit (`3847`) bzw. Hermes-Dashboard (`9119`) |
| Datei-Sync (Mutagen) | entfällt — Dateien über Cockpit-Explorer bzw. den Cloud-Client der Firma | `~/KI-OS` als lokaler Spiegel (Obsidian, Finder/Explorer) |
| Desktop-App | ja (nur `engine=claude`) | ja (nur `engine=claude`) |

Die zweite Achse ist die **Engine** der VM (`claude` | `hermes`) — die liest
der Skill selbst von der VM: auf `hermes` gibt es kein Cockpit, die Oberfläche
ist das Hermes-Dashboard, und die Hermes-Desktop-App verbindet sich per URL +
Session-Token statt über eine lokale Registrierung.

Die gesamte Mechanik liegt in fertigen, parametrisierten Skripten unter
`scripts/` (bash für macOS/Linux, PowerShell für natives Windows) — der Skill
orchestriert nur.

## Voraussetzungen

- macOS, Linux oder Windows
  - macOS / Linux: `ssh`, `curl` (Standard); macOS zusätzlich Homebrew
    (nur für Mutagen im tunnel-Modus)
  - Windows nativ: PowerShell 5.1+, Windows-OpenSSH-Client (vorinstalliert auf
    Windows 10/11; sonst installiert ihn `scripts/check-prereqs.ps1`, braucht
    Admin) und Git for Windows (Pflicht — Claude Code braucht auf nativem
    Windows die Git Bash). WSL2 bleibt als Alternative.
- Claude Code installiert (`https://claude.com/claude-code`)
- Vom Admin erhalten: entweder die **Login-URL** (gateway) oder
  **VM-Public-IP + VM-Username** (tunnel)

## Was passiert beim ersten Lauf

1. Zugangs-Modus abfragen (URL vom Admin → gateway, sonst tunnel)
2. SSH-Key erstellen (falls nicht vorhanden) + minimalen
   `~/.ssh/config`-Eintrag für den festen Alias `ki-os-vm` schreiben — der
   Public Key landet in der Zwischenablage
3. Key hinterlegen — **gateway:** selbst im Cockpit (Tab System →
   „SSH-Zugang"), kein Warten. **tunnel:** an den Admin schicken, dann Pause
   bis er bestätigt
4. SSH-Smoketest + User-Werte holen (ein Roundtrip: Engine, Ports, Hub-Backend,
   im tunnel-Modus das noVNC-Passwort, im gateway-Modus die URLs)
5. **Nur tunnel:** gehärtete SSH-Tunnel als Autostart (noVNC + Cockpit bzw.
   Hermes-Dashboard) und Mutagen-Sync `~/KI-OS`
6. Claude-Code-Desktop-App vorkonfigurieren (macOS/Windows, nur
   `engine=claude`): SSH-Host `ki-os-vm` + vertrauter Workspace — die VM
   erscheint direkt im Remote-Projekt-Switcher
7. Verifikation aller Komponenten

Autostart-Backends pro OS: LaunchAgents (macOS), systemd-User-Services (Linux),
Scheduled Tasks (Windows). Der Skill ist idempotent — ein erneuter Lauf ist das
Update.

## Danach: so arbeitest du

`engine=claude`:

- **Claude-Code-Desktop-App** (primär): Remote-Projekt `ki-os-vm` / `KI-OS`
- **Browser:** Cockpit + noVNC über die Gateway-URLs (gateway) bzw.
  `localhost:3847`/`6080` (tunnel) · `claude.ai/code` für eigene Sessions
- **Terminal:** `ssh ki-os-vm` → `cd ~/KI-OS && claude`
- **VS Code Remote-SSH** (Techniker): `references/vscode-remote-ssh.md`

`engine=hermes`:

- **Agent-Dashboard:** gateway `https://<user>-agent.…`, tunnel
  `http://localhost:9119` — oder die **Hermes-Desktop-App** (URL +
  Session-Token vom Admin, `references/hermes-desktop-app.md`)

Beide Engines:

- **Browser-Logins:** einmalig im VM-Chrome (noVNC) in die Zielsysteme einloggen
- **Dateien:** gateway → Cockpit-Explorer bzw. Cloud-Client der Firma;
  tunnel → lokaler Ordner `~/KI-OS`

## Quellen

- `SKILL.md` — Orchestrierung (Schritte, Inputs, Skript-Aufrufe)
- `scripts/` — parametrisierte Setup-Skripte (`.sh` = macOS/Linux,
  `.ps1` = natives Windows): `check-prereqs.ps1`, `setup-ssh`,
  `get-vm-values`, `setup-tunnels`, `setup-mutagen`,
  `register-desktop-app`, `verify`
- `references/tunnels.md` — Tunnel-Härtung (Warum) + Troubleshooting
- `references/mutagen.md` — Sync-Semantik, Ignores, Troubleshooting
- `references/ssh.md` — SSH-Details (BOM/ACL/Passphrase) + Fehlerbilder
- `references/desktop-app.md` — Claude-Code-Desktop-App (nur engine=claude)
- `references/hermes-desktop-app.md` — Hermes-Desktop-App: URL + Session-Token
  (nur engine=hermes)
- `references/vscode-remote-ssh.md` — VS Code Remote-SSH
- `references/ssh-pubkey-handoff.md` — Mail-/Slack-Vorlage für den Pubkey
  (tunnel-Modus bzw. Hermes-VMs ohne Cockpit-Self-Service)
- `references/api-keys.md` — API-Keys/OAuth (beide Engines); ab
  „Claude-Code-Auth" nur engine=claude
