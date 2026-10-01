# user-onboarding — Lokaler KI-OS-Onboarding-Skill

Claude-Code-Skill, den ein Mitarbeiter auf seinem lokalen Gerät
(Mac/Linux/Windows) installiert, um sich mit dem vom Admin angelegten
KI-OS-Workspace auf der Firmen-VM zu verbinden.

Workspaces, Browser und Logins leben auf der VM — lokal wird nur der Zugriff
eingerichtet. **Zugang ist immer das Gateway:** Cockpit, Hermes-Dashboard,
Artefakte und VM-Desktop laufen über HTTPS-URLs mit deinem Firmen-Login. **Der
Skill fragt als erstes, welche Adresse du vom Admin bekommen hast**, und fährt
dann einen von zwei Wegen — die Weiche ist die Engine der VM:

| | **Cockpit-Adresse** (`engine=claude\|hybrid`) | **reine Hermes-VM — Pfad H** (`engine=hermes`) |
|---|---|---|
| Woran erkennbar | Admin schickte eine **Cockpit-URL** (`https://<name>-cockpit.…`) + Firmen-Login | Admin schickte **Dashboard-URL** (`https://<name>-agent.…`) + VM-Desktop-Link |
| SSH-Key | trägst du **selbst im Cockpit** ein (Tab System → „SSH-Zugang") | **entfällt** — kein VM-Zugriff vom Gerät |
| Claude-Desktop-App | ja (Remote-Projekt `ki-os-vm` / `KI-OS`) | — |
| Hermes-Desktop-App | **Pflicht** auf `hybrid` (URL + **Firmen-Login**) | **Pflicht** (URL + **Firmen-Login**) |
| Dateien | Cockpit-Explorer bzw. Cloud-Client der Firma | Dashboard/VM-Desktop bzw. Cloud-Client der Firma |

Es gibt kein VNC-Passwort und keinen lokalen Datei-Spiegel.

Die gesamte Mechanik liegt in fertigen, parametrisierten Skripten unter
`scripts/` (bash für macOS/Linux, PowerShell für natives Windows) — der Skill
orchestriert nur.

## Voraussetzungen

- macOS, Linux oder Windows
  - macOS / Linux: `ssh`, `curl` (Standard)
  - Windows nativ: PowerShell 5.1+, Windows-OpenSSH-Client (vorinstalliert auf
    Windows 10/11; sonst installiert ihn `scripts/check-prereqs.ps1`, braucht
    Admin) und Git for Windows (Pflicht — Claude Code braucht auf nativem
    Windows die Git Bash). WSL2 bleibt als Alternative.
- Claude Code installiert (`https://claude.com/claude-code`)
- Vom Admin erhalten: die **Cockpit-Adresse** bzw. auf einer reinen Hermes-VM
  **Dashboard-Adresse + VM-Desktop-Link**

## Was passiert beim ersten Lauf

1. Adresse abfragen (Cockpit-Adresse → Claude-Stack, Dashboard-Adresse ohne
   Cockpit → Pfad H: weiter mit Punkt 5)
2. SSH-Key erstellen (falls nicht vorhanden) + minimalen
   `~/.ssh/config`-Eintrag für den festen Alias `ki-os-vm` schreiben — der
   Public Key landet in der Zwischenablage
3. Key selbst im Cockpit hinterlegen (Tab System → „SSH-Zugang"), kein Warten
4. SSH-Smoketest + User-Werte holen (ein Roundtrip: Engine, Display-Stack,
   Gateway-URLs)
5. Desktop-App: Claude-Code-Desktop-App vorkonfigurieren (macOS/Windows,
   `engine=claude|hybrid`: SSH-Host `ki-os-vm` + vertrauter Workspace — die VM
   erscheint direkt im Remote-Projekt-Switcher) bzw. Hermes-Desktop-App mit
   URL + Firmen-Login verbinden (`engine=hermes|hybrid`)
6. Verifikation aller Komponenten (nicht auf Pfad H)

Der Skill ist idempotent — ein erneuter Lauf ist das Update.

## Danach: so arbeitest du

`engine=claude`:

- **Claude-Code-Desktop-App** (primär): Remote-Projekt `ki-os-vm` / `KI-OS`
- **Browser:** Cockpit + VM-Desktop über die Gateway-URLs · `claude.ai/code`
  für eigene Sessions
- **Terminal:** `ssh ki-os-vm` → `cd ~/KI-OS && claude`
- **VS Code Remote-SSH** (Techniker): `references/vscode-remote-ssh.md`

`engine=hermes`:

- **Hermes-Desktop-App** (Pflicht): URL vom Admin, Anmeldung per Firmen-Login,
  `references/hermes-desktop-app.md`
- **Agent-Dashboard** im Browser als Fallback: `https://<user>-agent.…`

`engine=hybrid`: beides — Hermes-Desktop-App als Einstieg, daneben Cockpit +
Claude-Desktop-App.

Alle Engines:

- **Browser-Logins:** einmalig im VM-Chrome (VM-Desktop) in die Zielsysteme
  einloggen
- **Dateien:** über die VM (Cockpit-Explorer, Dashboard, VM-Desktop) bzw. den
  Cloud-Client der Firma

## Quellen

- `SKILL.md` — Orchestrierung (Schritte, Inputs, Skript-Aufrufe)
- `scripts/` — parametrisierte Setup-Skripte (`.sh` = macOS/Linux,
  `.ps1` = natives Windows): `check-prereqs.ps1`, `setup-ssh`,
  `get-vm-values`, `register-desktop-app`, `verify`
- `references/ssh.md` — SSH-Details (BOM/ACL/Passphrase) + Fehlerbilder
- `references/desktop-app.md` — Claude-Code-Desktop-App (nur engine=claude|hybrid)
- `references/hermes-desktop-app.md` — Hermes-Desktop-App: URL + Firmen-Login
  (engine=hermes|hybrid)
- `references/vscode-remote-ssh.md` — VS Code Remote-SSH
- `references/api-keys.md` — API-Keys/OAuth (beide Engines); ab
  „Claude-Code-Auth" nur engine=claude
