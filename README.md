# Mitarbyte KI-OS — Marketplace

Claude-Code-Plugins für Mitarbyte-KI-OS. Aktuell ein Plugin:

| Plugin | Wofür |
|---|---|
| `user-onboarding` | Lokales Onboarding für Mitarbeiter: SSH-Key, gehärtete noVNC-/Cockpit-Tunnel, Mutagen-Sync zur Firmen-VM. |

## Installation

In Claude Code (lokal auf deinem Mac/Linux/Windows-Gerät):

```
/plugin marketplace add Mitarbyte/marketplace
/plugin install user-onboarding@mitarbyte
/user-onboarding
```

## Updates

```
/plugin marketplace update mitarbyte
```

---

> Automatisch generiert aus `ki-os-template` (Source of Truth) via
> `scripts/sync-onboarding-plugin.sh`. Hier nichts von Hand editieren —
> Änderungen am Skill gehören ins Template.
