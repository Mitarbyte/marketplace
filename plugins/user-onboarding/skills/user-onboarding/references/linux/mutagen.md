# Mutagen-Sync (Linux)

**Pflicht-Bestandteil** des Setups (Schritt 9 in `SKILL.md`) — einer der
drei festen Autostarts (noVNC-Tunnel, Cockpit-Tunnel, Mutagen-Sync).

`ki-os-vm` ist der Default-SSH-Alias. Bei abweichendem Alias alle
Vorkommen ersetzen.

## Wozu

Identisch zur macOS-Referenz (`../macos/mutagen.md` → "Wozu"): echte
lokale Kopie des VM-Workspaces unter `~/KI-OS`, two-way, reconnectet
selbst, friert nicht ein. Ersetzt den frueheren SSHFS-Mount.

## 1. Installieren

Variante A — Homebrew (falls vorhanden):

```bash
command -v brew >/dev/null && brew install mutagen-io/mutagen/mutagen
```

Variante B — GitHub-Release-Binary (kein Homebrew noetig):

```bash
mkdir -p ~/.local/bin
URL=$(curl -fsSL https://api.github.com/repos/mutagen-io/mutagen/releases/latest \
    | grep -o '"browser_download_url": *"[^"]*linux_amd64[^"]*"' \
    | grep -o 'https[^"]*' | head -1)
curl -fsSL "$URL" | tar -xz -C ~/.local/bin mutagen
chmod +x ~/.local/bin/mutagen
# ~/.local/bin muss im PATH sein:
command -v mutagen || export PATH="$HOME/.local/bin:$PATH"
mutagen version
```

(ARM-Geraete: `linux_arm64` statt `linux_amd64`.)

## 2. Daemon-Autostart

`mutagen daemon register` unterstuetzt Linux nicht — stattdessen ein
systemd-User-Service nach dem bewaehrten Tunnel-Muster.

Datei: `~/.config/systemd/user/mutagen-daemon.service`
(`<MUTAGEN_BIN>` = Ausgabe von `command -v mutagen`, z.B.
`/home/<user>/.local/bin/mutagen` oder
`/home/linuxbrew/.linuxbrew/bin/mutagen`):

```ini
[Unit]
Description=Mutagen-Daemon (Sync-Sessions)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=<MUTAGEN_BIN> daemon run
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
```

Aktivieren (vorher einen evtl. per CLI autogestarteten Daemon stoppen,
sonst meldet die Unit "daemon already running"):

```bash
mutagen daemon stop 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user enable --now mutagen-daemon.service
systemctl --user status mutagen-daemon.service
```

**Linger nicht vergessen** (einmalig): `sudo loginctl enable-linger "$USER"`.

**WSL2:** systemd in `/etc/wsl.conf` aktivieren (siehe
`cockpit-systemd.md`). Achtung: Sync laeuft nur, solange die
WSL2-Instanz laeuft.

## 3. Session `ki-os` anlegen

Identisch zur macOS-Referenz — Idempotenz-Check, dann:

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

VM ist **Alpha** (gewinnt bei Konflikten), lokal `~/KI-OS` ist **Beta**.
Begruendung der Ignores (inkl. der bewusst **mitgesyncten** klickbaren
`.claude/skills`-Ansicht) + Konflikt-Semantik + Obsidian-Hinweis:
`../macos/mutagen.md` (gilt 1:1 auch fuer Linux — `portable`-Symlink-Modus
toleriert die relativen In-Root-Links).

> **Bestands-User:** Die Ignore-Liste wirkt nur beim Anlegen. Wer noch
> eine `ki-os`-Session mit dem alten `--ignore=".claude/skills"` hat, legt
> sie einmalig neu an (`mutagen sync terminate ki-os` + neu), damit die
> klickbare Skill-Ansicht lokal erscheint. Dateien bleiben erhalten.

## 4. Verifikation

```bash
mutagen sync list ki-os    # Status: "Watching for changes"
ls ~/KI-OS                 # zeigt CLAUDE.md, hub/, ...
```

## Troubleshooting

| Symptom | Loesung |
|---------|---------|
| `mutagen sync list` zeigt "Connecting..." dauerhaft | SSH testen: `ssh -o BatchMode=yes ki-os-vm true` |
| Daemon-Unit failed: "daemon already running" | `mutagen daemon stop`, dann `systemctl --user restart mutagen-daemon.service` |
| Sync laeuft nach Reboot nicht | `loginctl enable-linger` vergessen, oder Unit nicht enabled |
| "Conflicts" in `mutagen sync list` | `mutagen sync list ki-os --long`; VM-Version gewinnt — lokale Aenderung vorher wegsichern, falls gebraucht |
| Session kaputt/falsch konfiguriert | `mutagen sync terminate ki-os` + neu anlegen — Dateien bleiben erhalten |
