# user-onboarding — Lokaler KI-OS-Onboarding-Skill

Claude-Code-Skill, den ein Mitarbeiter auf seinem lokalen Gerät
(Mac/Linux/Windows) installiert, um sich mit dem vom Admin angelegten
KI-OS-Workspace auf der Firmen-VM zu verbinden.

Workspaces, Browser und Logins leben auf der VM — lokal wird nur der Zugriff
eingerichtet. **Zugang ist immer das Gateway:** Cockpit, Agent-Adresse,
Artefakte und (nur im Claude-Paket) VM-Desktop laufen über HTTPS-URLs mit
deinem Firmen-Login. **Der Skill fragt als erstes, welche Adresse du vom Admin
bekommen hast** — sie zeigt, welche Engine-Pakete die VM hat:

| | **Claude-Paket** — Cockpit-Adresse | **Hermes-Paket** — Agent-Adresse |
|---|---|---|
| Woran erkennbar | **Cockpit-URL** (`https://<name>-cockpit.…`) + Firmen-Login | **Agent-URL** (`https://<name>-agent.…`) + Firmen-Login |
| SSH-Key | trägst du **selbst im Cockpit** ein (Tab System → „SSH-Zugang") | — |
| Desktop-App | Claude-Desktop-App (Remote-Projekt `ki-os-vm` / `KI-OS`) | **Hermes-Desktop-App, Pflicht** (URL + **Firmen-Login**) |
| Anmeldungen bei Websites | VM-Chrome im VM-Desktop | **Desktop-App → Screen → Übernehmen** |
| Dateien | Cockpit-Explorer bzw. Cloud-Client der Firma | Desktop-App bzw. Cloud-Client der Firma |

Beide Adressen = beide Pakete, beide Spalten. Nur eine Agent-Adresse =
**Pfad H**: kein SSH-Key, kein Skript, kein VM-Zugriff vom Gerät.

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
- Vom Admin erhalten: die **Cockpit-Adresse** und/oder die **Agent-Adresse**

## Was passiert beim ersten Lauf

1. Adresse abfragen (Cockpit-Adresse → Claude-Paket, nur Agent-Adresse →
   Pfad H: weiter mit Punkt 5)
2. SSH-Key erstellen (falls nicht vorhanden) + minimalen
   `~/.ssh/config`-Eintrag für den festen Alias `ki-os-vm` schreiben — der
   Public Key landet in der Zwischenablage
3. Key selbst im Cockpit hinterlegen (Tab System → „SSH-Zugang"), kein Warten
4. SSH-Smoketest + User-Werte holen (ein Roundtrip: Engine-Pakete, VM-Desktop,
   Gateway-URLs)
5. Desktop-Apps: Claude-Desktop-App vorkonfigurieren (Claude-Paket,
   macOS/Windows: SSH-Host `ki-os-vm` + vertrauter Workspace) bzw.
   Hermes-Desktop-App mit URL + Firmen-Login verbinden (Hermes-Paket)
6. Verifikation aller Komponenten (nicht auf Pfad H)

Der Skill ist idempotent — ein erneuter Lauf ist das Update.

## Danach: so arbeitest du

Claude-Paket:

- **Claude-Code-Desktop-App** (primär): Remote-Projekt `ki-os-vm` / `KI-OS`
- **Browser:** Cockpit + VM-Desktop über die Gateway-URLs · `claude.ai/code`
  für eigene Sessions
- **Terminal:** `ssh ki-os-vm` → `cd ~/KI-OS && claude`
- **VS Code Remote-SSH** (Techniker): `references/vscode-remote-ssh.md`
- **Browser-Logins:** einmalig im VM-Chrome (VM-Desktop)

Hermes-Paket:

- **Hermes-Desktop-App** (Pflicht): URL vom Admin, Anmeldung per Firmen-Login,
  `references/hermes-desktop-app.md`
- **Browser-Logins:** im Screen der App (Übernehmen → anmelden → Zurückgeben)
- **Agent-Dashboard** im Browser als Fallback: `https://<user>-agent.…`

Beide Pakete: Hermes-Desktop-App als Einstieg, daneben Cockpit +
Claude-Desktop-App; Website-Logins je Paket einmal (eigenes Chrome-Profil).

Dateien immer über die VM bzw. den Cloud-Client der Firma.

## Quellen

- `SKILL.md` — Orchestrierung (Schritte, Inputs, Skript-Aufrufe)
- `scripts/` — parametrisierte Setup-Skripte (`.sh` = macOS/Linux,
  `.ps1` = natives Windows): `check-prereqs.ps1`, `setup-ssh`,
  `get-vm-values`, `register-desktop-app`, `verify`
- `references/ssh.md` — SSH-Details (BOM/ACL/Passphrase) + Fehlerbilder
- `references/desktop-app.md` — Claude-Code-Desktop-App (Claude-Paket)
- `references/hermes-desktop-app.md` — Hermes-Desktop-App: URL + Firmen-Login,
  Screen (Hermes-Paket)
- `references/vscode-remote-ssh.md` — VS Code Remote-SSH
- `references/api-keys.md` — API-Keys/OAuth (beide Pakete); ab
  „Claude-Code-Auth" nur Claude-Paket
