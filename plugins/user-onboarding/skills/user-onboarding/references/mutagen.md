# Mutagen-Sync — Hintergrund, Konflikt-Semantik, Troubleshooting

Den Pflicht-Autostart richtet `scripts/setup-mutagen.sh` (macOS/Linux) bzw.
`scripts/setup-mutagen.ps1` (Windows) ein — dieses Dokument erklärt das
**Warum** hinter Session-Konfiguration und Ignores.

## Wozu

Mutagen synchronisiert den VM-Workspace `/home/<VM_USER>/KI-OS` beidseitig in
den lokalen Ordner `~/KI-OS` (Windows: `%USERPROFILE%\KI-OS`):

- **Echte lokale Kopie** statt Netz-Mount — friert bei Verbindungsabbruch
  nicht ein, voller Speed beim Öffnen, offline lesbar
- **Reconnectet selbst** nach Schlaf/Netzwechsel (eigener Daemon)
- **Two-way:** lokale Edits gehen zur VM zurück, VM-Änderungen
  (Agent-Outputs) erscheinen lokal

Transport ist die bestehende SSH-Verbindung (`ki-os-vm`-Alias aus
`~/.ssh/config`) — kein extra Dienst, kein extra Account. Die
`ServerAliveInterval 15`-Optionen im Alias sorgen dafür, dass Mutagen eine
tote SSH-Session in ~45 s erkennt und reconnectet, statt bis zu 180 s in
„Connecting…" zu hängen.

## Daemon-Autostart pro OS

| OS | Mechanismus |
|----|-------------|
| macOS | `mutagen daemon register` (offizielle launchd-Integration) |
| Linux | systemd-User-Service `mutagen-daemon.service` (+ Linger); `daemon register` unterstützt Linux nicht |
| Windows | der gemeinsame Scheduled Task `ki-os-vm-watchdog` (angelegt von `setup-tunnels.ps1`, Schritt 7): sein 2-Min-Guard startet den Daemon unsichtbar (`wscript.exe`-Launcher, Fensterstil 0 — sonst poppt bei jedem Login ein Konsolenfenster mit Daemon-Logs auf), sobald mutagen installiert ist und kein `mutagen`-Prozess läuft |

> **Windows-Detail:** Beim Daemon prüft der Watchdog-Guard `Get-Process
> mutagen`; zusätzlich ist der **Daemon-Lock** der Backstop — `mutagen daemon
> run` bricht beim Doppelstart ab, *bevor* eine SSH-Verbindung aufgebaut
> wird, selbst ein blinder Respawn wäre hier leak-frei. Die Tunnel haben
> keinen solchen Lock und brauchen zwingend den expliziten Port-Listen-Check
> (`references/tunnels.md`). Beide Guards NICHT vermischen.

## Selbstheilung — Session-Watchdog

Der Daemon-Autostart hält nur den **Daemon-Prozess** am Leben. Mutagen
reconnectet die Session zwar selbst nach transienten Transport-Abrissen
(Schlaf/Netzwechsel) — **aber** eine Session, die nach langem **VM-Idle-Suspend**
in `Paused`/`Halted` landet, kommt **nicht** von allein zurück. VM-seitig
erscheint dann ein toter `mutagen-agent`, und lokale Skill-Outputs kommen nicht
mehr im Obsidian-Vault an, obwohl die VM-Seite gesund ist.

Deshalb läuft zusätzlich ein kleiner **Session-Watchdog** (~alle 2 min):

| OS | Mechanismus |
|----|-------------|
| macOS | LaunchAgent `com.<user>.ki-os-vm.mutagen-watchdog` (`StartInterval 120`) → `scripts/ki-os-mutagen-watchdog.sh` (aus `~/.local/bin/`) |
| Linux | systemd-User-Timer `ki-os-mutagen-watchdog.timer` (`OnUnitActiveSec=2min`) + oneshot-Service, ruft denselben Guard |
| Windows | im gemeinsamen `ki-os-vm-watchdog`-Task mit abgedeckt (2-Min-Tick resumt zusätzlich die Session) |

Der Guard ist idempotent: Steht die Session auf `Watching for changes`, tut er
nichts; jeder andere Zustand → `mutagen sync resume ki-os` (no-op auf laufender
Session, heilt aber `paused`/`halted`). Fehlt die Session ganz, greift der
Watchdog **nicht** (Neuanlegen braucht den VM-Pfad) → dann `/user-onboarding`
erneut laufen lassen. Manuell prüfen: `mutagen sync list ki-os` ·
Guard-Logs (macOS) `~/Library/Logs/ki-os-mutagen-watchdog*.log` ·
(Linux) `journalctl --user -u ki-os-mutagen-watchdog`.

## Session-Konfiguration

**Endpoint-Reihenfolge ist bewusst:** Die VM ist **Alpha** (erstes Argument),
der lokale Ordner ist **Beta**. Im Modus `two-way-resolved` gewinnt bei echten
Konflikten automatisch Alpha — also die VM, auf der der Agent arbeitet.

**Warum diese Ignores (Pflicht, nicht kürzen):**

| Ignore | Grund |
|--------|-------|
| `--ignore-vcs` (`.git`) | Git-Metadaten gehören VM-seitig — deckt das `.git` des Hub-Klons unter `hub/` ab. Lokal liegt nur der lesbare Arbeitsstand |
| `node_modules`, `.venv`, `__pycache__` | Abhängigkeits-/Build-Verzeichnisse — groß, maschinenspezifisch, auf der VM gebaut |
| `.obsidian/workspace*` | Obsidian-Fenster-Layout ist gerätespezifisch — würde sonst zwischen VM/Laptop hin- und herflattern |
| `.cache`, `dist`, `.next` | Build-/Browser-Caches |
| `.DS_Store` | macOS-Finder-Artefakte nicht auf die VM tragen |

**`.claude/skills` — macOS/Linux vs. Windows:**

- **macOS/Linux: wird bewusst mitgesynct** (kein Ignore). `sync-skills.sh`
  baut die Skill-Symlinks **relativ** in den Sync-Root
  (`../../hub/Skills/<cat>/<skill>`), sie lösen lokal korrekt auf
  `~/KI-OS/hub/Skills/…` auf → klickbare Skill-Ansicht. `.skill-profile`
  (ebenfalls gesynct) bleibt die Quelle, *welche* Skills aktiv sind. Der
  Default-Symlink-Modus (`portable`) toleriert relative In-Root-Links.
- **Windows: `--ignore=".claude/skills"` bleibt stehen.** Symlinks brauchen
  dort `SeCreateSymbolicLinkPrivilege` (Developer-Mode oder Admin); ohne das
  wirft der Sync Fehler. *Welche* Skills aktiv sind, zeigt `.skill-profile`
  und die Cockpit-Skill-Overview. **Opt-in:** Wer den Windows-Developer-Mode
  aktiviert (Einstellungen → System → Für Entwickler), kann die Session ohne
  dieses Ignore neu anlegen und bekommt dieselbe klickbare Ansicht.

**Ignore-Änderungen wirken nur beim Anlegen:** Eine bestehende Session
übernimmt neue Ignores nicht — einmalig neu anlegen
(`scripts/setup-mutagen.sh --vm-user <u> --recreate` bzw. `-Recreate`).
Dateien bleiben dabei erhalten.

## Konflikt-Semantik (dem User erklären)

- `two-way-resolved`: Bei gleichzeitiger Änderung derselben Datei auf beiden
  Seiten gewinnt die **VM** (Alpha) — die lokale Version wird überschrieben.
- Betriebs-Konvention: **Agent und Mensch bearbeiten nicht gleichzeitig
  dieselbe Datei.** Normale Arbeit erzeugt keine Konflikte.
- Status: `mutagen sync list ki-os` · live: `mutagen sync monitor ki-os` ·
  sofort syncen: `mutagen sync flush ki-os`.

## Obsidian

Den Vault auf dem **lokalen** Ordner `~/KI-OS` öffnen (Obsidian → „Open
folder as vault"). Friert nicht ein, offline lesbar, schnelle Suche. Die
Vault-Config (`.obsidian/`) kommt von der VM mit; nur die gerätespezifischen
`workspace*`-Dateien sind vom Sync ausgenommen.

## Round-Trip-Test

```bash
touch ~/KI-OS/.sync-test && mutagen sync flush ki-os && \
    ssh ki-os-vm 'ls ~/KI-OS/.sync-test' && \
    rm ~/KI-OS/.sync-test && mutagen sync flush ki-os
```

## Troubleshooting

| Symptom | Lösung |
|---------|---------|
| `mutagen: command not found` (Windows) | Neue PowerShell-Session öffnen (PATH-Update) oder `%USERPROFILE%\.local\bin\mutagen.exe` direkt aufrufen |
| „Connecting…" dauerhaft | SSH testen: `ssh -o BatchMode=yes ki-os-vm true` — wenn das hängt, ist es ein SSH-/Netz-Problem |
| „Conflicts" in `mutagen sync list` | `mutagen sync list ki-os --long` zeigt die Dateien; VM-Version gewinnt beim nächsten Sync — lokale Änderung vorher wegsichern, falls gebraucht |
| Daemon läuft nach Reboot nicht | macOS: `mutagen daemon register` + `start` erneut · Linux: Linger/Unit prüfen (`loginctl enable-linger`) · Windows: `ki-os-vm-watchdog`-Task prüfen (`AtLogOn` feuert nur beim echten Login) |
| Sync tot nach VM-Idle-Suspend, kommt nicht wieder (VM-seitig toter `mutagen-agent`) | Session steckt in `paused`/`halted` — der Session-Watchdog resumt binnen ~2 min; sofort: `mutagen sync resume ki-os`, bei `halted` `mutagen sync reset ki-os` (rescan, danach `resume`). Watchdog fehlt? `setup-mutagen.sh` erneut laufen lassen |
| Session steht auf `[Paused]` | `mutagen sync resume ki-os` (macht der Watchdog automatisch) |
| Daemon-Unit failed: „daemon already running" (Linux) | `mutagen daemon stop`, dann `systemctl --user restart mutagen-daemon.service` |
| Watchdog-Task „beendet sich sofort" (Windows) | Erwartet: der 2-Min-Tick sieht laufende Tunnel + Daemon und beendet sich — die Prozesse selbst laufen weiter (`Get-Process mutagen`) |
| Daemon-Fenster geht beim Login auf (Windows) | Alter Task startet `mutagen.exe` noch sichtbar — `setup-tunnels.ps1` erneut laufen lassen (konsolidiert inhaltsbasiert auf den unsichtbaren `ki-os-vm-watchdog`) |
| Session kaputt/falsch konfiguriert | `--recreate`/`-Recreate` — Dateien bleiben erhalten |
| Erst-Sync dauert lange | Normal bei großem Workspace — `mutagen sync monitor ki-os` zeigt Fortschritt |
| Sync-Fehler wegen Symlinks (Windows) | `.claude/skills`-Ignore fehlt in der Session → mit `-Recreate` neu anlegen |
