---
name: user-onboarding
description: "Lokales Onboarding fuer einen Mitarbeiter, der einen vom Admin bereits auf einer Firmen-VM angelegten KI-OS-Workspace nutzen will. Use when someone says 'KI-OS einrichten', 'vm-zugriff einrichten', 'ssh-key fuer firmen-vm', 'mit der firmen-vm verbinden', 'lokales setup fuer hub-vm', 'novnc-tunnel einrichten', 'vm-browser im browser ansehen', 'cockpit-tunnel einrichten', 'mutagen-sync fuer ki-os', 'ki-os ordner lokal syncen', 'obsidian-vault fuer ki-os', 'altes ki-os-setup migrieren', 'chrome-bridge entfernen', 'sshfs abloesen', '/user-onboarding'. Also trigger when someone just got their VM-Username + IP from an admin and wants to start using their workspace, or when a v1 user (Chrome-Bridge/SSHFS/vm-oauth) wants to migrate to the new setup. Skill macht ausschliesslich LOKALE Schritte: SSH-Key, minimaler ~/.ssh/config-Eintrag, drei Pflicht-Autostarts (gehaerteter noVNC-Tunnel lokal 6080, gehaerteter Cockpit-Tunnel lokal 3847, Mutagen-Daemon + Sync-Session ki-os fuer ~/KI-OS) sowie der ~/.claude.json-Workspace-Eintrag fuer die Claude-Code-Desktop-App. Alle drei Autostarts sind Pflicht-Bestandteile, keine Auswahl. Der Workspace auf der VM ist bereits vom Admin angelegt und wird hier nicht angefasst; Browser + Logins laufen auf der VM (noVNC) — Chrome-Bridge, vm-oauth und SSHFS sind obsolet und werden bei Bestands-Usern zurueckgebaut. Unterstuetzte Plattformen: macOS, Linux, Windows (nativ ueber PowerShell + Windows-OpenSSH + Scheduled Tasks; WSL2 als Alternative)."
---

## Was dieser Skill macht

Richtet auf dem lokalen macOS-/Linux-/Windows-Geraet des Mitarbeiters
alles ein, damit er sich auf seine vom Admin angelegte VM verbinden und
produktiv arbeiten kann:

1. SSH-Key generieren (falls noch nicht vorhanden) und an den Admin senden
2. Minimaler `~/.ssh/config`-Eintrag fuer den gewaehlten SSH-Alias
   (Default `ki-os-vm`, idempotent — KEIN ControlMaster, KEINE Forwards)
3. **WARTEN auf Admin-Freigabe** — User muss vor Schritt 6 vom Admin die
   Bestaetigung haben, dass sein User auf der VM angelegt ist und der
   SSH-Key hinterlegt wurde
4. SSH-Smoketest + User-Werte von der VM holen: Cockpit-Port
   (`mitarbyte cockpit-port`), noVNC-Port + noVNC-Passwort
   (`~/.config/ki-os/display.env` + `~/.config/ki-os/vnc.pass`)
5. **Pflicht-Autostart 1:** gehaerteter SSH-Tunnel zum noVNC
   (lokal `6080` → VM `<NOVNC_PORT>`) — VM-Browser live im lokalen
   Browser unter `http://localhost:6080/vnc.html?resize=scale`
6. **Pflicht-Autostart 2:** gehaerteter SSH-Tunnel zum Cockpit
   (lokal `3847` → VM `<COCKPIT_PORT>`) — `http://localhost:3847`
7. **Pflicht-Autostart 3:** Mutagen installieren, Daemon-Autostart,
   Sync-Session `ki-os` (`VM:~/KI-OS` ↔ lokal `~/KI-OS`, two-way-resolved)
8. **Zum Abschluss** — den SSH-Workspace (`ssh:<SSH_ALIAS>:/home/<VM_USER>/KI-OS`)
   in `~/.claude.json` registrieren, sodass die Claude-Code-Desktop-App ihn
   ohne weiteres Trust-Prompt direkt im Remote-Projekt-Switcher anzeigt
9. Verifikation aller Komponenten + bei Bestands-Usern: Migration vom
   alten Setup (Chrome-Bridge, vm-oauth, SSHFS — alles obsolet)

**Nicht-Ziele:**

- VM-seitiges Setup (Workspace, Display-Stack, Cockpit — alles Admin-Sache)
- Hub-Klone lokal (Workspace + Hub liegen auf der VM; lokal gibt es nur
  die Mutagen-Kopie unter `~/KI-OS`)
- Browser-Logins (macht der User spaeter selbst im noVNC-Tab, siehe
  "Browser-Logins & OAuth" unten)

---

## Architektur in 30 Sekunden

Auf der VM laeuft pro Mitarbeiter (vom Admin provisioniert):

- ein eigenes virtuelles Display mit **headed Chrome** (eigenes Profil) —
  darin passieren alle Browser-Logins und der Agent-Browser ist live sichtbar
- **noVNC** auf `127.0.0.1:<NOVNC_PORT>` — der Blick auf dieses Display,
  Passwort-geschuetzt
- das **Cockpit** auf `127.0.0.1:<COCKPIT_PORT>` — Scheduler, Token-Usage,
  Skills
- der **Workspace** `/home/<VM_USER>/KI-OS` — normaler Ordner mit dem Hub als geklontem Git-Repo darunter (`hub/`)

Lokal richtet dieser Skill nur drei dauerhafte Verbindungen ein:

| Verbindung | Lokal | VM | Zweck |
|---|---|---|---|
| noVNC-Tunnel | `localhost:6080` | `127.0.0.1:<NOVNC_PORT>` | VM-Browser ansehen + bedienen |
| Cockpit-Tunnel | `localhost:3847` | `127.0.0.1:<COCKPIT_PORT>` | Cockpit-Web-UI |
| Mutagen-Sync | `~/KI-OS` | `/home/<VM_USER>/KI-OS` | Workspace als lokaler Ordner (Obsidian, Finder/Explorer) |

Die lokalen Ports sind fuer ALLE Mitarbeiter gleich (jeder hat seinen
eigenen Laptop): noVNC immer `6080`, Cockpit immer `3847`. Nur die
VM-seitigen Ports sind pro User verschieden.

Primaerer Arbeitszugang ist die **Claude-Code-Desktop-App** (verbindet
sich selbst per SSH). Fallbacks: claude.ai/code im Browser, `ssh` +
`claude` im Terminal, VS Code Remote-SSH.

---

## Voraussetzungen

Vor dem Start klaert der Skill diese Punkte mit dem User per `AskUserQuestion`:

1. **Betriebssystem** — macOS, Linux oder Windows? Auto-Detect ueber
   `uname -s` (bash) bzw. `$IsWindows` (PowerShell); nur bei Ambiguitaet
   fragen. WSL2-Ubuntu wird als Linux behandelt.
2. **VM-Public-IP** — vom Admin erhalten (z.B. `1.2.3.4`)
3. **VM-Username** — vom Admin erhalten (z.B. `alice`)
4. **SSH-Alias** — kurzer Name fuer die VM in `~/.ssh/config` (Default
   `ki-os-vm`; alternativ z.B. `<kunde>-vm`, wenn der User mehrere
   Hub-VMs hat). Der Alias bestimmt auch die Namen der Autostart-Dienste.
5. **Email-Adresse** — fuer SSH-Key-Kommentar (Default: `git config --global user.email`)

**Feste Setup-Bestandteile (keine Auswahl, immer installiert):**

- `novnc-tunnel-autostart` — gehaerteter SSH-Tunnel zum pro-User-noVNC
- `cockpit-tunnel-autostart` — gehaerteter SSH-Tunnel zum pro-User-Cockpit
- `mutagen-sync` — Daemon-Autostart + Sync-Session `ki-os` fuer `~/KI-OS`

Der Skill fragt diese Komponenten **nicht** ab — sie gehoeren fest zum
Setup. Backend pro OS: LaunchAgents (macOS), systemd-User-Services
(Linux), Scheduled Tasks (Windows).

## Konvention: SSH-Alias als zentrale Variable

Im gesamten Ablauf wird der in Schritt 2 gewaehlte Wert als `<SSH_ALIAS>`
verwendet (Default: `ki-os-vm`). In den Referenz-Dokumenten steht ebenfalls
`ki-os-vm` als Default — falls der User einen anderen Alias waehlt, ersetzt
der Skill **konsequent in allen Konfigurationen, Pfaden und Befehlen**.

## Konvention: Tunnel laufen als eigene Prozesse, nicht in der SSH-Config

Die `~/.ssh/config` enthaelt KEINE `LocalForward`-/`RemoteForward`-Zeilen.
Beide Tunnel laufen als eigene, gehaertete Autostart-Prozesse mit `-L`
direkt im Kommando — auf allen drei Plattformen identisch. So bleibt die
SSH-Config minimal, und interaktive SSH-Sessions (Terminal, Desktop-App,
VS Code) sind von den Tunneln vollstaendig entkoppelt.

---

## Ablauf

### Schritt 1 — Betriebssystem erkennen

```bash
# Bash-Variante (macOS/Linux/WSL)
case "$(uname -s)" in
    Darwin)             OS=macos ;;
    Linux)              OS=linux ;;        # inkl. WSL2-Ubuntu
    MINGW*|MSYS*|CYGWIN*) OS=windows ;;    # Git Bash etc. auf Windows
    *)                  OS=unknown ;;
esac
```

```powershell
# PowerShell-Variante (native Windows)
if ($IsWindows -or $env:OS -eq 'Windows_NT') { $OS = 'windows' }
elseif ($IsMacOS)   { $OS = 'macos' }
elseif ($IsLinux)   { $OS = 'linux' }
else                { $OS = 'unknown' }
```

Bei `windows` per `AskUserQuestion` klaeren, ob der User **native Windows-
Variante** oder **WSL2** nutzen will:

- **Native Windows** — PowerShell + Windows-OpenSSH + Scheduled Tasks
  + Git for Windows (Pflicht — Claude Code braucht auf nativem Windows
  die Git Bash, siehe Schritt 1.5). Default fuer Windows-User.
- **WSL2** — User startet `wsl` und durchlaeuft den Linux-Pfad. Einfacher
  fuer User, die schon WSL2 nutzen. Achtung: systemd muss in WSL2 aktiv
  sein (`/etc/wsl.conf`: `[boot]\nsystemd=true`, danach `wsl --shutdown`).

### Schritt 1.5 — Windows-Vorbedingung pruefen (nur Native-Windows)

Skip diesen Schritt fuer macOS, Linux und WSL2.

Zwei harte Vorbedingungen:

**1. Windows-OpenSSH-Client** (bei Windows 10/11 normalerweise
vorinstalliert):

```powershell
Get-Command ssh -ErrorAction SilentlyContinue
# vorhanden → fertig
# fehlt → als Administrator installieren:
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

Der native Windows-OpenSSH reicht fuer SSH + Tunnel vollstaendig —
ControlMaster wird nirgendwo mehr gebraucht.

**2. Git for Windows** — **Pflicht**, nicht fuer dieses Setup, sondern
weil Claude Code auf nativem Windows (Desktop-App wie CLI) die
mitgelieferte Git Bash voraussetzt:

```powershell
Get-Command git -ErrorAction SilentlyContinue
# vorhanden → fertig
# fehlt → installieren:
winget install --id Git.Git -e --source winget
```

Wichtig: Git for Windows nur installieren — dessen `ssh.exe` NICHT vor
den Windows-OpenSSH in den PATH stellen. Alle SSH-/Tunnel-Schritte in
diesem Skill nutzen den nativen Client
(`C:\Windows\System32\OpenSSH\ssh.exe`).

Lies basierend auf `$OS` (und ggf. Windows-Native vs. WSL2) die passende
Detail-Doku:

- macOS: `references/macos/ssh-setup.md`,
  `references/macos/novnc-tunnel.md`,
  `references/macos/cockpit-launchagent.md`,
  `references/macos/mutagen.md`
- Linux (inkl. WSL2): `references/linux/ssh-setup.md`,
  `references/linux/novnc-tunnel.md`,
  `references/linux/cockpit-systemd.md`,
  `references/linux/mutagen.md`
- Windows (nativ): `references/windows/ssh-setup.md`,
  `references/windows/novnc-tunnel.md`,
  `references/windows/cockpit-scheduledtask.md`,
  `references/windows/mutagen.md`

Diese Dateien enthalten die exakten Commands. Der Skill orchestriert; die
Details kommen aus den Referenzdateien.

### Schritt 2 — User-Inputs sammeln

`AskUserQuestion` fuer die Pflichtfelder (VM-IP, VM-Username, SSH-Alias,
Email). Default fuer Email aus `git config --global user.email`. Default
fuer SSH-Alias: `ki-os-vm`. **Keine Frage nach optionalen Komponenten** —
noVNC-Tunnel, Cockpit-Tunnel und Mutagen-Sync werden immer eingerichtet.

Speichere die Antworten in lokalen Shell-Variablen (`VM_IP`, `VM_USER`,
`SSH_ALIAS`, `EMAIL`) — sie werden in den naechsten Schritten mehrfach
gebraucht. Aus `SSH_ALIAS` ergeben sich automatisch die Namen der
Autostart-Dienste (LaunchAgent-Labels, Unit-Namen, Task-Namen).

### Schritt 3 — SSH-Key generieren

Pruefen ob `~/.ssh/id_ed25519` schon existiert:

```bash
test -f ~/.ssh/id_ed25519 && echo EXISTS || echo MISSING
```

- `EXISTS`: User fragen ob bestehender Key genutzt werden soll (Default: ja).
  Falls ja → Schritt 3 ueberspringen.
- `MISSING`: `ssh-keygen -t ed25519 -C "$EMAIL" -f ~/.ssh/id_ed25519 -N ""`
  (Passphrase leer; User kann nachtraeglich per `ssh-keygen -p` setzen).

Public-Key ausgeben und in die Zwischenablage kopieren:

```bash
cat ~/.ssh/id_ed25519.pub | pbcopy   # macOS
cat ~/.ssh/id_ed25519.pub | xclip -selection clipboard   # Linux (falls xclip da)
```

```powershell
# Windows (PowerShell)
Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub" | Set-Clipboard
```

Dem User mitteilen:

> **Dein Public Key ist in der Zwischenablage.**
>
> Schick ihn jetzt an deinen Admin (Slack, Mail, Signal — egal). Der Admin
> braucht den Key, um deinen User auf der VM anzulegen.
>
> Public Key (auch hier zum Kopieren):
> ```
> <inhalt von id_ed25519.pub>
> ```

Fertige Mail-/Slack-Vorlagen: `references/ssh-pubkey-handoff.md` — der
Skill gibt die passende direkt aus.

### Schritt 4 — ~/.ssh/config Basis-Eintrag (minimal)

Idempotent einen `Host ${SSH_ALIAS}`-Block in `~/.ssh/config` einfuegen.
Vorher pruefen, ob der Block schon existiert
(`grep -q "^Host ${SSH_ALIAS}$" ~/.ssh/config`).

Falls existiert: User fragen ob ueberschrieben werden soll. **Wenn der
bestehende Block noch v1-Zeilen enthaelt (`RemoteForward`, `LocalForward`,
`ControlMaster`, `ControlPath`, `ControlPersist`, oder es existiert ein
`Host ${SSH_ALIAS}-mux`-Block): immer ersetzen** — das ist Teil der
Migration (Schritt 12 raeumt den Rest auf).

Der komplette Block — mehr braucht es nicht:

```
Host <SSH_ALIAS>
    HostName <VM_IP>
    User <VM_USER>
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
```

KEIN `ControlMaster`, KEIN `RemoteForward`, KEIN `LocalForward`, KEIN
Zwei-Alias-Konstrukt. Die Tunnel laufen als eigene Autostart-Prozesse
(Schritte 7 + 8). Details + OS-Eigenheiten (Windows: BOM-frei schreiben,
ACL-Reparatur): `references/<os>/ssh-setup.md`.

### Schritt 5 — Warten auf Admin-Freigabe

Bevor der Skill weitermacht, muss der Admin den SSH-Key auf der VM
hinterlegt und den User komplett eingerichtet haben (Workspace,
Cockpit-Service, Display-Stack mit noVNC). Per `AskUserQuestion`:

> "Hat dein Admin bestaetigt, dass dein User auf der VM angelegt ist
> (Workspace + Zugang bereit)?"
>
> Optionen: "Ja, kann's testen" | "Noch nicht — pausiere hier"

Wenn "Noch nicht": Skill pausiert, User kann `/user-onboarding` spaeter
nochmal aufrufen — der Skill ist idempotent.

### Schritt 6 — Connection-Smoketest + User-Werte holen

```bash
ssh -o BatchMode=yes <SSH_ALIAS> true 2>&1
```

Fehlerbilder (Permission denied, Timeout, Host-Key): siehe
`references/<os>/ssh-setup.md` → Smoketest/Troubleshooting.

Bei Erfolg drei Werte von der VM holen:

**1. Cockpit-Port:**

```bash
ssh <SSH_ALIAS> 'mitarbyte cockpit-port 2>/dev/null || echo "MISSING_CLI"'
```

Druckt einen Block mit `Port auf der VM: <NNNNN>` (Schema `30000 + UID`,
z.B. `31001`). Den Wert extrahieren → `COCKPIT_PORT`. Falls
`MISSING_CLI`: VM-CLI nicht installiert — Admin kontaktieren.

**2. noVNC-Port:**

```bash
ssh <SSH_ALIAS> 'grep "^NOVNC_PORT=" ~/.config/ki-os/display.env | cut -d= -f2'
```

Schema `6080 + (UID - 1000)`, z.B. `6081` fuer den zweiten User →
`NOVNC_PORT`. Falls die Datei fehlt: Der Display-Stack ist fuer diesen
User noch nicht provisioniert — Admin kontaktieren, dann hier weitermachen.

**3. noVNC-Passwort:**

```bash
ssh <SSH_ALIAS> 'cat ~/.config/ki-os/vnc.pass'
```

Das Klartext-Passwort dem User zeigen — er gibt es spaeter einmalig im
noVNC-Tab ein (der Browser merkt es sich nicht; gerne in den
Passwort-Manager).

### Schritt 7 — Pflicht-Autostart: noVNC-Tunnel

Gehaerteter Background-SSH-Tunnel `6080:127.0.0.1:<NOVNC_PORT>`, der nach
Reboot/Schlaf/Netzwechsel automatisch wieder hochkommt. Danach ist der
VM-Browser dauerhaft unter `http://localhost:6080/vnc.html?resize=scale` erreichbar.

| OS | Backend | Referenz |
|----|---------|----------|
| macOS | LaunchAgent `com.<mac-user>.ssh-tunnel.<SSH_ALIAS>-novnc` | `references/macos/novnc-tunnel.md` |
| Linux | systemd-User-Service `<SSH_ALIAS>-novnc-tunnel.service` | `references/linux/novnc-tunnel.md` |
| Windows | Scheduled Task `<SSH_ALIAS>-novnc-tunnel` | `references/windows/novnc-tunnel.md` |

Haertung in allen Varianten identisch (NICHT neu erfinden — exakt die
Vorlagen aus den Referenzen nutzen): Supervisor-Restart
(macOS `KeepAlive.SuccessfulExit=false` / Linux `Restart=always` /
Windows 2-Min-Repetition-Watchdog, der ein **liveness-guarded** Guard-Skript
aufruft — startet `ssh` nur, wenn der lokale Port noch nicht lauscht) plus
`ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=60
-o ServerAliveCountMax=3`. Windows braucht den Watchdog, weil "Restart on
failure" allein langlaufende Tunnel nach einem spaeten Crash nicht
zuverlaessig neu startet. **Wichtig:** der Windows-Watchdog darf `ssh`
NICHT blind alle 2 Min respawnen (alte Variante < 2026-06-18) — das leakt
auf der VM Tausende toter SSH-Sessions (Details + Begruendung:
`references/windows/cockpit-scheduledtask.md` → "Warum diese Options").
Der Repetition-Trigger braucht zwingend ein `-RepetitionDuration` — fehlt es,
feuert der Task auf Win11 24H2 nur einmal (toter Watchdog). **NICHT**
`[TimeSpan]::MaxValue` verwenden: der Task Scheduler lehnt das mit
HRESULT `0x80041318` (out of range) ab (real auf Win11 24H2 aufgetreten,
2026-06-20). Stattdessen `(New-TimeSpan -Days 9999)` — registriert als `P9999D`
(~27 Jahre), akzeptiert und effektiv unendlich. Die Windows-Tunnel-Schritte sind zudem self-healing: sie
entfernen beim Re-Setup jeden alt/falsch benannten Tunnel-Task auf demselben
lokalen Port (inhaltsbasiert), bevor sie den korrekten neu anlegen.

Idempotenz: Wenn das Plist / die Unit / der Task schon existiert, vor dem
Schreiben mit der `bootout`-/`disable`-/`Unregister`-Sequenz entladen und
neu registrieren. Bestehende Werte werden ueberschrieben — bewusst, damit
Konfig-Drift nicht unbemerkt bleibt.

### Schritt 8 — Pflicht-Autostart: Cockpit-Tunnel

Identisches Muster, zweiter Tunnel: `3847:127.0.0.1:<COCKPIT_PORT>`.
Danach ist das Cockpit dauerhaft unter `http://localhost:3847` erreichbar.

| OS | Backend | Referenz |
|----|---------|----------|
| macOS | LaunchAgent `com.<mac-user>.ssh-tunnel.<SSH_ALIAS>-cockpit` | `references/macos/cockpit-launchagent.md` |
| Linux | systemd-User-Service `<SSH_ALIAS>-cockpit-tunnel.service` | `references/linux/cockpit-systemd.md` |
| Windows | Scheduled Task `<SSH_ALIAS>-cockpit-tunnel` | `references/windows/cockpit-scheduledtask.md` |

Hinweis fuer Bestands-User: Der lokale Cockpit-Port ist jetzt einheitlich
`3847` (frueher lief der Autostart-Tunnel auf `13847` — alte Bookmarks
anpassen).

### Schritt 9 — Pflicht-Autostart: Mutagen-Sync

Mutagen ersetzt den frueheren SSHFS-Mount komplett: statt eines
FUSE-Mounts (der bei Netzunterbrechung einfror) haelt Mutagen eine echte
lokale Kopie des Workspaces unter `~/KI-OS` und synchronisiert beidseitig.
Offline lesbar, voller Speed, reconnectet selbst.

Drei Teilschritte (Details + OS-Eigenheiten: `references/<os>/mutagen.md`):

**9a — Installieren:**

- macOS: `brew install mutagen-io/mutagen/mutagen`
- Linux: Homebrew falls vorhanden, sonst GitHub-Release-Binary
- Windows: GitHub-Release-Zip nach `%USERPROFILE%\.local\bin\`
  (kein offizielles winget-Paket)

**9b — Daemon-Autostart:**

- macOS: `mutagen daemon register` (offizielle launchd-Integration)
- Linux: systemd-User-Service `mutagen-daemon.service` (+ Linger)
- Windows: Scheduled Task `mutagen-daemon` startet `mutagen daemon run`
  ueber einen **unsichtbaren VBS-Launcher** (`wscript.exe`, Fensterstil 0
  — sonst poppt bei jedem Login ein Konsolenfenster mit Daemon-Logs auf),
  supervised per 2-Min-Watchdog wie die Tunnel

**9c — Session `ki-os` anlegen** (VM ist Alpha und gewinnt bei Konflikten;
lokal `~/KI-OS` ist Beta):

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
    <SSH_ALIAS>:/home/<VM_USER>/KI-OS ~/KI-OS
```

Die Ignores sind Pflicht (Git-Metadaten inkl. `hub/.git` bleiben
VM-seitig; Build-/Browser-Caches und geraetespezifische Obsidian-Fenster-
Layouts werden nicht gesynct). `.claude/skills` wird auf **macOS/Linux
bewusst mitgesynct**: `sync-skills.sh` baut die Skill-Symlinks **relativ**
in den Sync-Root (`../../hub/Skills/…`), sie loesen lokal korrekt auf
`~/KI-OS/hub/Skills/…` auf → klickbare Skill-Ansicht. **Auf Windows
bleibt `--ignore=".claude/skills"` stehen** (Symlinks brauchen dort
`SeCreateSymbolicLinkPrivilege`/Developer-Mode, sonst Sync-Fehler) — siehe
`references/windows/mutagen.md`. Begruendung, Konflikt-Semantik und der
Bestands-User-Hinweis (Session einmalig neu anlegen, damit die Ansicht
erscheint): `references/<os>/mutagen.md`.

**Obsidian:** Der Vault wird kuenftig auf dem **lokalen** Ordner `~/KI-OS`
geoeffnet (statt frueher auf dem SSHFS-Mount) — gleiche UX, friert nicht
ein, offline lesbar.

**Hinweis Windows:** Mutagen ist die beschlossene Architektur, auf
Windows aber noch nicht im Kundenbetrieb verifiziert — bei Problemen
(Daemon startet nicht, Sync haengt nach Netzwechsel) an den Admin.

### Schritt 10 — SSH-Workspace in Claude-Code-Settings registrieren

Pflicht-Bestandteil. Traegt den Remote-Workspace als bekanntes Projekt in
`~/.claude.json` ein, damit die Claude-Code-Desktop-App (und `claude` im
Terminal) den VM-Workspace ohne erneutes Trust-Prompt direkt im
Remote-Projekt-Switcher anzeigt.

**Schluessel-Konvention:** Claude Code speichert Remote-Projekte unter
`.projects["ssh:<SSH_ALIAS>:<remote-pfad>"]`. Fuer das KI-OS-Setup ist
das immer:

```
ssh:<SSH_ALIAS>:/home/<VM_USER>/KI-OS
```

**Settings-Datei finden** (Cross-Platform identisch im User-Home):

| OS | Pfad |
|----|------|
| macOS / Linux | `$HOME/.claude.json` |
| Windows | `$env:USERPROFILE\.claude.json` |

**Eintrag schreiben** (idempotent per `jq`, atomar via tmp-File):

```bash
# macOS / Linux
SETTINGS="$HOME/.claude.json"
KEY="ssh:${SSH_ALIAS}:/home/${VM_USER}/KI-OS"

# Settings-Datei muss existieren (Claude Code legt sie beim ersten Start an)
if [ ! -f "$SETTINGS" ]; then
    echo "WARN: $SETTINGS fehlt — bitte einmalig 'claude' lokal starten und Schritt 10 erneut laufen lassen."
    exit 0
fi

# jq ist Pflicht — auf Mac via Homebrew, auf Linux via apt
command -v jq >/dev/null || { echo "jq fehlt — bitte installieren (brew/apt)"; exit 1; }

tmp=$(mktemp)
jq --arg k "$KEY" '
  .projects = (.projects // {}) |
  .projects[$k] = ((.projects[$k] // {}) + {
    "allowedTools": ((.projects[$k].allowedTools) // []),
    "mcpContextUris": ((.projects[$k].mcpContextUris) // []),
    "enabledMcpjsonServers": ((.projects[$k].enabledMcpjsonServers) // []),
    "disabledMcpjsonServers": ((.projects[$k].disabledMcpjsonServers) // []),
    "hasTrustDialogAccepted": true,
    "projectOnboardingSeenCount": ((.projects[$k].projectOnboardingSeenCount) // 0),
    "hasClaudeMdExternalIncludesApproved": ((.projects[$k].hasClaudeMdExternalIncludesApproved) // false),
    "hasClaudeMdExternalIncludesWarningShown": ((.projects[$k].hasClaudeMdExternalIncludesWarningShown) // false)
  })
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

echo "OK: $KEY eingetragen in $SETTINGS"
```

```powershell
# Native Windows (PowerShell) — ohne jq via ConvertFrom-Json
# WICHTIG: PowerShell-5.1-kompatibel. Windows liefert nativ Windows
# PowerShell 5.1; deren ConvertFrom-Json kennt KEIN -AsHashtable, und
# Hashtable-Merge (+) gibt es ebenfalls erst ab PowerShell 7. Beides hier
# vermeiden — sonst bleibt $json bei $null und das nachfolgende
# ConvertTo-Json wuerde "null" in die .claude.json schreiben (Config kaputt).
$settings = "$env:USERPROFILE\.claude.json"
$key = "ssh:${SSH_ALIAS}:/home/${VM_USER}/KI-OS"

if (-not (Test-Path $settings)) {
    Write-Host "WARN: $settings fehlt — bitte einmalig 'claude' starten und Schritt 10 wiederholen."
    return
}

# Sicherheitsnetz: Backup vor dem Schreiben (einmal pro Lauf ueberschrieben)
Copy-Item $settings "$settings.bak-onboarding" -Force

# Als PSCustomObject laden (5.1-kompatibel)
$json = Get-Content $settings -Raw | ConvertFrom-Json

# .projects sicherstellen (ohne Hashtable-Indizierung)
if (-not ($json.PSObject.Properties.Name -contains 'projects') -or $null -eq $json.projects) {
    $json | Add-Member -NotePropertyName projects -NotePropertyValue ([PSCustomObject]@{}) -Force
}

$existing = $json.projects.PSObject.Properties[$key]
if ($existing) {
    # Bestehenden Eintrag nur ergaenzen — Trust-Flag setzen, Rest unangetastet
    if ($existing.Value.PSObject.Properties['hasTrustDialogAccepted']) {
        $existing.Value.hasTrustDialogAccepted = $true
    } else {
        $existing.Value | Add-Member -NotePropertyName hasTrustDialogAccepted -NotePropertyValue $true -Force
    }
} else {
    $entry = [PSCustomObject]@{
        allowedTools = @()
        mcpContextUris = @()
        enabledMcpjsonServers = @()
        disabledMcpjsonServers = @()
        hasTrustDialogAccepted = $true
        projectOnboardingSeenCount = 0
        hasClaudeMdExternalIncludesApproved = $false
        hasClaudeMdExternalIncludesWarningShown = $false
    }
    # Schluessel enthaelt ':' und '/' → per Add-Member setzen, nicht per Punkt-Notation
    $json.projects | Add-Member -NotePropertyName $key -NotePropertyValue $entry -Force
}

# BOM-frei schreiben (Set-Content -Encoding utf8 in 5.1 schreibt ein BOM,
# an dem manche JSON-Parser stolpern) — wie der ssh/config-Schreibweg
$out = $json | ConvertTo-Json -Depth 100
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($settings, $out, $enc)
Write-Host "OK: $key eingetragen in $settings"
```

`hasTrustDialogAccepted: true` ist das entscheidende Feld — ohne den
Eintrag wuerde Claude Code beim ersten Connect den Trust-Dialog werfen.

**Verifikation:**

```bash
jq -r --arg k "ssh:${SSH_ALIAS}:/home/${VM_USER}/KI-OS" '.projects[$k]' ~/.claude.json
```

Sollte das Objekt mit `"hasTrustDialogAccepted": true` zurueckliefern.

**Hinweis:** Wenn `~/.claude.json` noch gar nicht existiert (Claude Code
nie gestartet), gibt der Skill nur eine Warnung aus und ueberspringt
diesen Schritt — der Eintrag wird beim naechsten `/user-onboarding`-Lauf
nachgezogen. Der Skill-Re-Run ist idempotent.

### Schritt 11 — Verifikation

Alle vier Komponenten pruefen, bevor der Skill "fertig" meldet:

**1. noVNC erreichbar + Passwort funktioniert:**

```bash
curl -fsS -o /dev/null -w '%{http_code}' http://localhost:6080/vnc.html
# erwartet: 200
```

Dann den User aktiv testen lassen: `http://localhost:6080/vnc.html?resize=scale` im
Browser oeffnen, "Connect" klicken, das noVNC-Passwort aus Schritt 6
eingeben. Er sollte den VM-Desktop sehen (ggf. leer/grau, solange kein
Chrome laeuft — das ist okay).

**2. Cockpit erreichbar:**

```bash
curl -fsS -o /dev/null -w '%{http_code}' http://localhost:3847
# erwartet: 200 (oder 30x)
```

**3. Mutagen-Session gruen:**

```bash
mutagen sync list ki-os
# Status: "Watching for changes" und keine Konflikte/Probleme
ls ~/KI-OS
# zeigt den Workspace-Inhalt (CLAUDE.md, hub/, ...)
```

**4. Desktop-App verbindet:** User oeffnet die Claude-Code-Desktop-App →
Remote-Projekt-Switcher → `<SSH_ALIAS>` / `KI-OS` waehlen. Es darf kein
Trust-Prompt erscheinen, und eine Session auf der VM startet.

Schlaegt etwas fehl → Troubleshooting-Tabellen in den jeweiligen
Referenz-Dokumenten.

### Schritt 12 — Migration / Background-Autostarts aktualisieren (Bestands-User)

Zwei Faelle, beide nur fuer Bestands-User:

**12a — v2-Bestands-User (haben schon noVNC/Cockpit/Mutagen):** Ein erneuter
`/user-onboarding`-Lauf IST die Migration — die Schritte 7–9 re-deployen die
Background-Autostarts auf den aktuellen Stand. Das ist Routine, kein Sonderfall.
Unter **Windows** raeumen die Tunnel-Schritte dabei automatisch alt oder falsch
benannte Tunnel-Tasks weg (inhaltsbasiert ueber den `-L <lokalport>`-Forward,
nicht ueber den Task-Namen) und legen den Task mit korrektem
`-RepetitionDuration` neu an. Damit heilt sich ein vor 2026-06-19 fehlerhaft
konfigurierter Watchdog (Task feuerte nur einmal / leakte SSH-Sessions) beim
naechsten Lauf von selbst — ohne separates Fix-Dokument und ohne dass der User
etwas Spezielles tun muss. Einfach den Skill normal durchlaufen lassen.

**12b — v1-Altlasten (Chrome-Bridge + vm-oauth + SSHFS):**
Nur relevant, wenn der User schon einmal mit dem alten Setup (v1:
Chrome-Bridge + vm-oauth + SSHFS) onboardet wurde. Erkennungsmerkmale —
mindestens eines davon vorhanden:

```bash
# macOS / Linux
ls ~/Library/LaunchAgents/ 2>/dev/null | grep -E 'chrome-bridge|sshfs'   # macOS
systemctl --user list-unit-files 2>/dev/null | grep -E 'chrome-bridge|sshfs'  # Linux
test -f ~/.local/bin/vm-oauth && echo V1_FOUND
grep -E 'RemoteForward|ControlMaster' ~/.ssh/config 2>/dev/null
```

```powershell
# Windows
Get-ScheduledTask | Where-Object { $_.TaskName -match 'chrome-bridge|sshfs' }
Test-Path "$env:USERPROFILE\.local\bin\vm-oauth.ps1"
```

Wenn nichts gefunden: Schritt ueberspringen. Sonst die komplette
Rueckbau-Anleitung in `references/migration-v1.md` durcharbeiten — Kurzfassung:

1. Alte Autostarts stoppen + entfernen (Chrome-Bridge, SSHFS-Mount,
   alter Cockpit-Tunnel auf 13847)
2. SSHFS-Mount unmounten, Mount-Verzeichnis entfernen
3. Helper loeschen: `~/.local/bin/vm-oauth`, `~/.local/bin/mac-chrome-bridge`
   (Windows: `vm-oauth.ps1`, `win-chrome-bridge.ps1`, `win-sshfs-mount.ps1`)
4. `~/.ssh/config` bereinigen: `RemoteForward`-/`LocalForward`-/
   `ControlMaster`-/`ControlPath`-/`ControlPersist`-Zeilen + den ganzen
   `Host <SSH_ALIAS>-mux`-Block entfernen (passiert i.d.R. schon in Schritt 4)
5. Optional: altes lokales Bridge-Chrome-Profil `~/.chrome-<SSH_ALIAS>`
   loeschen
6. VM-seitig den obsoleten `CHROME_BRIDGE_PORT`-Export aus `~/.bashrc`
   entfernen (Kommando in `references/migration-v1.md`)

> **Wichtig fuer den User:** Die Browser-Logins lebten bisher im lokalen
> Bridge-Chrome. Nach der Migration muessen sie **einmalig neu** im
> VM-Chrome gemacht werden — `http://localhost:6080/vnc.html?resize=scale` oeffnen und
> in die Zielsysteme (Google, GitHub, CRM, ...) einloggen.

### Schritt 13 — Abschluss-Zusammenfassung

Zeige dem User eine Tabelle mit dem Status aller Komponenten:

```
## Onboarding abgeschlossen

| Komponente                       | Status |
|----------------------------------|--------|
| OS                               | macOS / Linux / Windows |
| SSH-Key                          | Erstellt / Vorhanden |
| ~/.ssh/config <SSH_ALIAS>        | Eingetragen (minimal) |
| SSH-Verbindung                   | OK |
| noVNC-Tunnel (lokal 6080)        | Aktiv — http://localhost:6080/vnc.html?resize=scale |
| Cockpit-Tunnel (lokal 3847)      | Aktiv — http://localhost:3847 |
| Mutagen-Session ki-os            | Watching for changes — ~/KI-OS |
| Claude-Code-Settings (~/.claude.json) | SSH-Workspace registriert |
| Migration v1-Setup               | Durchgefuehrt / Nicht noetig |
```

Naechste Schritte fuer den User:

1. **Arbeiten** — primaer ueber die **Claude-Code-Desktop-App**
   (Remote-Projekt `<SSH_ALIAS>` / `KI-OS`). Fallbacks:
   - **Browser:** `claude.ai/code` → eigene Remote-Session
   - **Terminal:** `ssh <SSH_ALIAS>` → `cd ~/KI-OS && claude`
   - **VS Code Remote SSH** (Techniker): `references/<os>/vscode-remote-ssh.md`
     (macOS/Windows; auf Linux funktioniert die macOS-Anleitung analog)
2. **Claude-Login (einmalig):** im noVNC-Browser (`http://localhost:6080/vnc.html?resize=scale`)
   in **claude.ai** einloggen — das ist der einzige Schritt, den du selbst machst.
   Daraus richtet die VM **automatisch** beides ein:
   - den **Full-Scope-OAuth-Login**, den `claude remote-control` braucht (der
     `ki-os-relogin`-Watcher loggt `claude` selbst ein bzw. heilt bei Ablauf).
   - den **Long-lived, inference-only Token** fuer interaktive/headless
     `claude`-Sessions ohne Re-Login — wird automatisch via `ki-os-setup-token`
     erzeugt und in `~/.config/ki-os/claude-token.env` abgelegt (nichts zu tun).

   Hintergrund, Abgrenzung der Token-Typen + manueller Fallback
   (`ki-os-setup-token --force`) in `references/api-keys.md`.
3. **Browser-Logins (einmalig):** `http://localhost:6080/vnc.html?resize=scale` oeffnen
   und im VM-Chrome in die Zielsysteme einloggen — siehe naechster Abschnitt.
4. **Dateien & Obsidian:** `~/KI-OS` ist der lokale Spiegel des Workspaces —
   als Obsidian-Vault oeffnen, im Finder/Explorer nutzen, in jedem Editor
   bearbeiten. Aenderungen syncen automatisch.
5. **Token-Setup:** Falls dein Hub API-Keys braucht: `references/api-keys.md`.

---

## Browser-Logins & OAuth (Doku fuer den User)

Alles laeuft auf der VM — lokal gibt es keinen Bridge-Chrome mehr:

- **Browser-Logins (Google, GitHub-Web, CRM, ...):** Im noVNC-Tab
  (`http://localhost:6080/vnc.html?resize=scale`) laeuft der VM-Chrome mit deinem
  eigenen Profil. Dort einmalig einloggen — die Sessions persistieren auf
  der VM und stehen dem Agent zur Verfuegung. **Keine privaten/Banking-
  Logins** in diesem Profil — der Agent kann auf alles zugreifen.
- **OAuth-Flows von CLIs auf der VM** (`gh auth login`,
  `gws auth login`, MCP-OAuth): auf der VM mit dem `ki-os-auth`-Wrapper
  starten (z.B. `ki-os-auth gh auth login`) — der Browser oeffnet sich im
  noVNC-Tab, Loopback-Callbacks funktionieren, weil CLI und Browser auf
  derselben VM laufen.
- **Device-/Paste-Code-Flows** (`claude auth login`, `gh` Device-Flow):
  Code + URL erscheinen im Chat/Terminal — die URL im **lokalen** Browser
  oeffnen und den Code eingeben. Kein Sonderfall, kein Helper noetig.
- Der fruehere `vm-oauth`-Helper ist obsolet und wird in Schritt 12
  entfernt.

---

## Hinweise

- **Sprache:** Kommunikation mit dem User auf Deutsch. Config-Dateien und
  Code auf Englisch.
- **Idempotent:** Alle Schritte pruefen den Zustand. Bestehende Configs
  werden nur nach expliziter User-Confirmation ueberschrieben (Ausnahme:
  v1-Altlasten in `~/.ssh/config` werden immer ersetzt).
- **Plattform:** macOS, Linux (inkl. WSL2) und Windows (nativ via
  PowerShell + Windows-OpenSSH + Scheduled Tasks). Windows-User koennen
  alternativ den WSL2-Pfad waehlen, wenn sie schon WSL2 nutzen.
- **Sicherheit:** SSH-Private-Keys nie ausgeben oder loggen. Das
  noVNC-Passwort ist ein lokales Schutz-Geheimnis des Users — nicht in
  Configs oder Logs schreiben, nur dem User zeigen. API-Tokens werden in
  diesem Skill gar nicht angefasst.
