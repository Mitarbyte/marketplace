# Mitarbyte KI-OS — user-onboarding

Lokales Onboarding-Skill für Mitarbeiter: SSH-Key, gehärtete
noVNC-/Cockpit-Tunnel und Mutagen-Sync zur Firmen-VM.

## Installation — Desktop-App, Web & Terminal

Eine Zeile installiert den Skill nach `~/.claude/skills/user-onboarding/`;
von dort lädt ihn **jede** Claude-Code-Umgebung (Desktop-App,
claude.ai/code und Terminal). Kein GitHub-Login, kein ZIP nötig.

**macOS / Linux** (Terminal):

```
curl -fsSL https://raw.githubusercontent.com/Mitarbyte/marketplace/main/install.sh | bash
```

**Windows** (PowerShell):

```
irm https://raw.githubusercontent.com/Mitarbyte/marketplace/main/install.ps1 | iex
```

Danach Claude Code starten (Desktop-App oder `claude` im Terminal) und
eingeben:

```
/user-onboarding
```

## Update

Denselben Installer noch einmal ausführen — er überschreibt den Skill
in-place.

## Alternative: als Plugin (nur Terminal-CLI)

Wer ausschließlich das Terminal nutzt, kann den Skill auch als Plugin
installieren:

```
claude plugin marketplace add Mitarbyte/marketplace
claude plugin install user-onboarding@mitarbyte
```

> Hinweis: `/plugin`-Befehle gibt es **nur im Terminal-CLI**, nicht in
> der Desktop-App oder im Web — dort den Installer oben verwenden.

---

> Automatisch generiert aus `ki-os-template` (Source of Truth) via
> `scripts/sync-onboarding-plugin.sh`. Hier nichts von Hand editieren —
> Änderungen am Skill gehören ins Template.
