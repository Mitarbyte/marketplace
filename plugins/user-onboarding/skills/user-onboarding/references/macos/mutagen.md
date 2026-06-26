# Mutagen-Sync (macOS)

**Pflicht-Bestandteil** des Setups (Schritt 9 in `SKILL.md`) — einer der
drei festen Autostarts (noVNC-Tunnel, Cockpit-Tunnel, Mutagen-Sync).

`ki-os-vm` ist der Default-SSH-Alias. Bei abweichendem Alias alle
Vorkommen ersetzen.

## Wozu

Mutagen synchronisiert den VM-Workspace `/home/<VM_USER>/KI-OS`
beidseitig in den lokalen Ordner `~/KI-OS`. Ersetzt den frueheren
SSHFS-Mount:

- **Echte lokale Kopie** statt FUSE-Mount — friert bei
  Verbindungsabbruch nicht ein, voller Speed beim Oeffnen, offline lesbar
- **Reconnectet selbst** nach Schlaf/Netzwechsel (eigener Daemon)
- **Two-way:** lokale Edits gehen zur VM zurueck, VM-Aenderungen
  (Agent-Outputs) erscheinen lokal

Transport ist die bestehende SSH-Verbindung (`ki-os-vm`-Alias aus
`~/.ssh/config`) — kein extra Dienst, kein extra Account.

## 1. Installieren

```bash
brew install mutagen-io/mutagen/mutagen
mutagen version
```

Falls Homebrew fehlt: erst `https://brew.sh` folgen (Standard auf
jedem Entwickler-Mac), dann obigen Befehl.

## 2. Daemon-Autostart

Mutagen bringt eine offizielle launchd-Integration mit:

```bash
mutagen daemon register   # legt einen LaunchAgent fuer den Daemon an
mutagen daemon start      # jetzt sofort starten
```

Damit startet der Daemon bei jedem Login automatisch; die Sessions sind
im Daemon persistiert und laufen nach Reboot von selbst weiter.

## 3. Session `ki-os` anlegen

Idempotenz-Check zuerst:

```bash
mutagen sync list ki-os >/dev/null 2>&1 && echo "EXISTS" || echo "MISSING"
```

Wenn `EXISTS`: Session zeigen (`mutagen sync list ki-os`) und nur bei
abweichender Konfiguration neu anlegen (`mutagen sync terminate ki-os`
und dann neu). Wenn `MISSING`:

> **Bestands-User:** Die Ignore-Liste wirkt nur beim **Anlegen** der
> Session. Wer bereits eine `ki-os`-Session aus der Zeit mit
> `--ignore=".claude/skills"` hat, muss sie einmalig neu erstellen, damit
> die klickbare Skill-Ansicht lokal erscheint:
> `mutagen sync terminate ki-os` und dann neu mit der unten stehenden
> (aktualisierten) Liste anlegen. Dateien bleiben erhalten.

```bash
mutagen sync create \
    --name=ki-os \
    --sync-mode=two-way-resolved \
    --ignore-vcs \
    --ignore="node_modules" \
    --ignore=".venv" \
    --ignore="__pycache__" \
    --ignore=".obsidian/workspace*" \
    --ignore=".cache" \
    --ignore="dist" \
    --ignore=".next" \
    --ignore=".DS_Store" \
    ki-os-vm:/home/<VM_USER>/KI-OS ~/KI-OS
```

**Endpoint-Reihenfolge ist bewusst:** Die VM ist **Alpha** (erstes
Argument), der lokale Ordner ist **Beta**. Im Modus `two-way-resolved`
gewinnt bei echten Konflikten automatisch Alpha — also die VM, auf der
der Agent arbeitet.

**Warum diese Ignores (Pflicht, nicht kuerzen):**

| Ignore | Grund |
|--------|-------|
| `--ignore-vcs` (`.git`) | Git-Metadaten gehoeren VM-seitig — deckt das `.git` des Hub-Klons unter `hub/` ab (bzw. auf Bestands-VMs das Workspace- und Submodul-`.git`). Lokal liegt nur der lesbare Arbeitsstand |
| `node_modules`, `.venv`, `__pycache__` | Abhaengigkeits-/Build-Verzeichnisse — gross, maschinenspezifisch, auf der VM gebaut |
| `.obsidian/workspace*` | Obsidian-Fenster-Layout ist geraetespezifisch — wuerde sonst zwischen VM/Laptop hin- und herflattern |
| `.cache`, `dist`, `.next` | Build-/Browser-Caches |
| `.DS_Store` | macOS-Finder-Artefakte nicht auf die VM tragen |

**`.claude/skills` wird bewusst mitgesynct** (kein Ignore). Die
Skill-Symlinks baut `sync-skills.sh` **relativ** in den Sync-Root hinein
(`../../hub/Skills/<cat>/<skill>` statt absoluter VM-Pfade) — lokal loesen
sie also korrekt auf `~/KI-OS/hub/Skills/…` auf, weil `hub/` ebenfalls
gesynct ist. Damit ist die aktive Skill-Ansicht lokal sichtbar und
**klickbar**: ein Klick auf `~/KI-OS/.claude/skills/<skill>` oeffnet direkt
die Quelle unter `~/KI-OS/hub/Skills/.../SKILL.md`. `.skill-profile`
(ebenfalls gesynct) bleibt die Single Source of Truth, *welche* Skills
aktiv sind. Der Default-Symlink-Modus (`portable`) toleriert relative
In-Root-Links auf macOS — kein zusaetzlicher Schalter noetig.

## 4. Verifikation

```bash
mutagen sync list ki-os
# Status: "Watching for changes", keine Conflicts/Problems

ls ~/KI-OS
# zeigt CLAUDE.md, hub/, ...

# Round-Trip-Test:
touch ~/KI-OS/.sync-test && mutagen sync flush ki-os && \
    ssh ki-os-vm 'ls ~/KI-OS/.sync-test' && \
    rm ~/KI-OS/.sync-test && mutagen sync flush ki-os
```

## Konflikt-Semantik (dem User erklaeren)

- Modus `two-way-resolved`: bei gleichzeitiger Aenderung derselben Datei
  auf beiden Seiten gewinnt die **VM** (Alpha) — die lokale Version wird
  ueberschrieben.
- Betriebs-Konvention: **Agent und Mensch bearbeiten nicht gleichzeitig
  dieselbe Datei.** Normale Arbeit (lokal editieren, Agent schreibt
  andere Dateien) erzeugt keine Konflikte.
- Status jederzeit: `mutagen sync list ki-os`; live: `mutagen sync
  monitor ki-os`; sofort syncen: `mutagen sync flush ki-os`.

## Obsidian

Den Vault auf dem **lokalen** Ordner `~/KI-OS` oeffnen (Obsidian →
"Open folder as vault"). Gleiche UX wie frueher mit dem SSHFS-Mount,
aber: friert nicht ein, offline lesbar, schnelle Suche. Die Vault-Config
(`.obsidian/`) kommt von der VM mit; nur die geraetespezifischen
`workspace*`-Dateien sind vom Sync ausgenommen.

## Troubleshooting

| Symptom | Loesung |
|---------|---------|
| `mutagen sync list` zeigt "Connecting..." dauerhaft | SSH testen: `ssh -o BatchMode=yes ki-os-vm true` — wenn das haengt, ist es ein SSH-/Netz-Problem |
| "Conflicts" in `mutagen sync list` | `mutagen sync list ki-os --long` zeigt die Dateien; VM-Version gewinnt beim naechsten Sync — lokale Aenderung vorher wegsichern, falls gebraucht |
| Daemon laeuft nach Reboot nicht | `mutagen daemon register` erneut ausfuehren, dann `mutagen daemon start` |
| Session kaputt/falsch konfiguriert | `mutagen sync terminate ki-os` und Session neu anlegen (Abschnitt 3) — Dateien bleiben erhalten |
| Erst-Sync dauert lange | Normal bei grossem Workspace — `mutagen sync monitor ki-os` zeigt Fortschritt |
