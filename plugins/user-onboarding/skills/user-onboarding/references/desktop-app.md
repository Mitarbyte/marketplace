# Claude-Code-Desktop-App vorkonfigurieren — Hintergrund

Die Einträge schreibt `scripts/register-desktop-app.sh` (macOS/Linux) bzw.
`scripts/register-desktop-app.ps1` (Windows). Dieses Dokument erklärt, warum
es **zwei** Dateien braucht, und liefert den manuellen Fallback.

## Warum zwei Dateien

Die Desktop-App verbindet sich selbst per SSH, kennt die VM aber **nur, wenn
sie in zwei getrennten Dateien hinterlegt ist** — der `~/.claude.json`-Eintrag
allein reicht nicht (deshalb tauchte die VM früher nicht im
Verbindungs-Dialog auf):

| Datei | Was sie bewirkt |
|---|---|
| `ssh_configs.json` (App-Support-Verzeichnis) | macht `ki-os-vm` als **gespeicherte SSH-Verbindung** im Connect-Dialog sichtbar + als **Trusted-Host** (kein Host-Trust-Prompt) |
| `~/.claude.json` (`.projects["ssh:ki-os-vm:/home/<VM_USER>/KI-OS"]`) | macht den **Workspace-Ordner** vorab vertraut (`hasTrustDialogAccepted: true` — kein Projekt-Trust-Prompt) |

Beide zusammen = die App zeigt `ki-os-vm` an und öffnet `~/KI-OS` ohne ein
einziges Prompt.

**Pfade:**

| OS | ssh_configs.json | .claude.json |
|----|------------------|--------------|
| macOS | `~/Library/Application Support/Claude/ssh_configs.json` | `~/.claude.json` |
| Windows | `%APPDATA%\Claude\ssh_configs.json` | `%USERPROFILE%\.claude.json` |
| Linux | — (keine Linux-Desktop-App) | `~/.claude.json` (gilt für Terminal-CLI) |

Linux-User arbeiten über `claude.ai/code` (Browser) oder
`ssh ki-os-vm` + `claude` im Terminal.

## Neustart-Pflicht

Die laufende App liest `ssh_configs.json` **nur beim Start** — ein neuer
Eintrag erscheint erst nach vollständigem Neustart (macOS: Cmd+Q, nicht nur
Fenster schließen). Die App schreibt die Datei nur beim expliziten
Hinzufügen/Ändern einer Verbindung in der UI; ein externer Schreibvorgang
überlebt einen normalen Neustart auch bei zuvor offener App (Smoke-Test
2026-06-28 auf macOS). Taucht der Host wider Erwarten nicht auf: Schritt bei
**geschlossener App** wiederholen.

## Manueller Fallback

Falls der Host nicht auftaucht: in der Desktop-App von Hand eine
SSH-Verbindung anlegen und als Host `ki-os-vm` eintragen — HostName, User und
Key liefert die `~/.ssh/config`. Einmal verbinden, Trust-Prompt bestätigen,
fertig.

## Verifikation per CLI

```bash
# macOS — Host in ssh_configs.json hinterlegt?
jq -e '.configs[] | select(.sshHost=="ki-os-vm")' \
  "$HOME/Library/Application Support/Claude/ssh_configs.json" >/dev/null \
  && echo "OK"

# Workspace-Eintrag (alle OS)
jq -r --arg k "ssh:ki-os-vm:/home/<VM_USER>/KI-OS" '.projects[$k]' ~/.claude.json
# -> Objekt mit "hasTrustDialogAccepted": true
```

## Hinweis: ~/.claude.json fehlt

Wenn `~/.claude.json` noch nicht existiert (Claude Code lokal nie gestartet),
überspringt das Skript den Eintrag mit einer Warnung — einmalig `claude`
starten und den Schritt wiederholen. Der Skill-Re-Run ist idempotent.
