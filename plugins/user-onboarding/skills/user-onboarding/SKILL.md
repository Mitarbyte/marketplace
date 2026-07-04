---
name: user-onboarding
description: "Lokales Onboarding fuer einen Mitarbeiter, der einen vom Admin bereits auf einer Firmen-VM angelegten KI-OS-Workspace nutzen will. Use when someone says 'KI-OS einrichten', 'vm-zugriff einrichten', 'ssh-key fuer firmen-vm', 'mit der firmen-vm verbinden', 'lokales setup fuer hub-vm', 'novnc-tunnel einrichten', 'vm-browser im browser ansehen', 'cockpit-tunnel einrichten', 'mutagen-sync fuer ki-os', 'ki-os ordner lokal syncen', 'obsidian-vault fuer ki-os', '/user-onboarding'. Also trigger when someone just got their VM-Username + IP from an admin and wants to start using their workspace, or when an existing user wants to refresh/repair their local setup (re-run is the update). Skill macht ausschliesslich LOKALE Schritte ueber parametrisierte Skripte in scripts/: SSH-Key, minimaler ~/.ssh/config-Eintrag, drei Pflicht-Autostarts (gehaerteter noVNC-Tunnel lokal 6080, gehaerteter Cockpit-Tunnel lokal 3847, Mutagen-Daemon + Sync-Session ki-os fuer ~/KI-OS) sowie die Desktop-App-Vorkonfiguration auf macOS/Windows (SSH-Host ki-os-vm in ssh_configs.json + ~/.claude.json-Workspace-Eintrag). Der SSH-Alias ist fest ki-os-vm und wird nicht abgefragt. Alle drei Autostarts sind Pflicht-Bestandteile, keine Auswahl. Der Workspace auf der VM ist bereits vom Admin angelegt und wird hier nicht angefasst; Browser + Logins laufen im VM-Chrome (noVNC-Tab). Unterstuetzte Plattformen: macOS, Linux, Windows (nativ ueber PowerShell + Windows-OpenSSH + Scheduled Tasks; WSL2 als Alternative)."
---

## Was dieser Skill macht

Richtet auf dem lokalen macOS-/Linux-/Windows-Gerät des Mitarbeiters alles
ein, damit er auf seiner vom Admin angelegten VM produktiv arbeiten kann:

1. SSH-Key + minimaler `~/.ssh/config`-Eintrag (fester Alias `ki-os-vm`) —
   Public Key geht an den Admin
2. **Pflicht-Autostart 1:** gehärteter SSH-Tunnel zum noVNC
   (lokal `6080` → VM `<NOVNC_PORT>`) — VM-Browser live unter
   `http://localhost:6080/vnc.html?resize=scale`
3. **Pflicht-Autostart 2:** gehärteter SSH-Tunnel zum Cockpit
   (lokal `3847` → VM `<COCKPIT_PORT>`) — `http://localhost:3847`
4. **Pflicht-Autostart 3:** Mutagen-Daemon + Sync-Session `ki-os`
   (`VM:~/KI-OS` ↔ lokal `~/KI-OS`, two-way, VM gewinnt Konflikte)
5. Claude-Code-Desktop-App vorkonfigurieren (macOS/Windows): SSH-Host in
   `ssh_configs.json` + vertrauter Workspace in `~/.claude.json`
6. Verifikation aller Komponenten

**Die gesamte Mechanik liegt in fertigen, parametrisierten Skripten unter
`scripts/`** — der Skill orchestriert nur: Inputs einsammeln, Skripte mit
Argumenten aufrufen, Output-Marker auswerten, User führen. Die Skripte NICHT
im Chat nachbauen oder abwandeln; bei Problemen erklären die
`references/`-Dokumente das Warum.

**Nicht-Ziele:** VM-seitiges Setup (Admin-Sache), lokale Hub-Klone (lokal
gibt es nur die Mutagen-Kopie `~/KI-OS`), Browser-Logins (macht der User
später selbst im noVNC-Tab).

---

## Architektur in 30 Sekunden

Auf der VM läuft pro Mitarbeiter (vom Admin provisioniert): ein eigenes
virtuelles Display mit **headed Chrome** (darin alle Browser-Logins, der
Agent-Browser live sichtbar), **noVNC** auf `127.0.0.1:<NOVNC_PORT>`
(passwortgeschützt), das **Cockpit** auf `127.0.0.1:<COCKPIT_PORT>`
(Scheduler, Token-Usage, Skills) und der **Workspace**
`/home/<VM_USER>/KI-OS` (normaler Ordner, Hub als Git-Klon unter `hub/`).

Lokal richtet dieser Skill nur drei dauerhafte Verbindungen ein:

| Verbindung | Lokal | VM | Zweck |
|---|---|---|---|
| noVNC-Tunnel | `localhost:6080` | `127.0.0.1:<NOVNC_PORT>` | VM-Browser ansehen + bedienen |
| Cockpit-Tunnel | `localhost:3847` | `127.0.0.1:<COCKPIT_PORT>` | Cockpit-Web-UI |
| Mutagen-Sync | `~/KI-OS` | `/home/<VM_USER>/KI-OS` | Workspace als lokaler Ordner (Obsidian, Finder/Explorer) |

Die lokalen Ports sind für ALLE Mitarbeiter gleich (jeder hat seinen eigenen
Laptop); nur die VM-seitigen Ports sind pro User verschieden. Primärer
Arbeitszugang ist die **Claude-Code-Desktop-App**; Fallbacks: claude.ai/code,
`ssh` + `claude` im Terminal, VS Code Remote-SSH
(`references/vscode-remote-ssh.md`).

## Konventionen

- **SSH-Alias fest `ki-os-vm`** — wird nie abgefragt (jeder Mitarbeiter hat
  genau eine Firmen-VM). Alle Service-Namen (LaunchAgent-Labels, Unit-/
  Task-Namen) und die Desktop-App-Einträge leiten sich daraus ab.
- **Drei Pflicht-Autostarts, keine Auswahl** — noVNC-Tunnel, Cockpit-Tunnel,
  Mutagen-Sync werden immer eingerichtet. Backends pro OS: LaunchAgents
  (macOS), systemd-User-Services (Linux), Scheduled Tasks (Windows).
- **Tunnel laufen als eigene Prozesse, nicht in der SSH-Config** — die
  `~/.ssh/config` enthält KEINE Forward-Zeilen, kein ControlMaster
  (`references/ssh.md`).
- **Skript-Aufrufe:** `SKILL_DIR` ist das Verzeichnis dieser SKILL.md (bei
  Mitarbeiter-Installation `~/.claude/skills/user-onboarding`).
  - macOS/Linux/WSL2: `bash "$SKILL_DIR/scripts/<name>.sh" <args>`
  - Windows nativ: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\<name>.ps1" <args>`
- **Sprache:** Mit dem User Deutsch; Skripte/Configs sind englisch/ASCII.

---

## Ablauf

### Schritt 1 — Betriebssystem erkennen

`uname -s` (bash: `Darwin`/`Linux`) bzw. PowerShell (`$env:OS` =
`Windows_NT`). Nur bei Ambiguität nachfragen. WSL2-Ubuntu = Linux-Pfad.

Bei Windows per `AskUserQuestion` klären: **native Windows-Variante**
(Default; PowerShell + Windows-OpenSSH + Scheduled Tasks) oder **WSL2**
(User startet `wsl` und durchläuft den Linux-Pfad; systemd muss in WSL2
aktiv sein — `/etc/wsl.conf`: `[boot]\nsystemd=true`, danach
`wsl --shutdown`).

### Schritt 2 — Vorbedingungen (nur natives Windows)

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\check-prereqs.ps1"
```

Prüft/installiert in einem Durchlauf: Windows-OpenSSH-Client (Install braucht
Admin — bei `MISSING_ADMIN` den User eine Admin-PowerShell öffnen lassen) und
Git for Windows (Pflicht für Claude Code auf nativem Windows). macOS/Linux:
überspringen.

### Schritt 3 — User-Inputs sammeln

`AskUserQuestion`: **VM-Public-IP** und **VM-Username** (beides vom Admin
erhalten), **Email** für den Key-Kommentar (Default:
`git config --global user.email`). Keine weiteren Fragen — Alias und
Komponenten stehen fest.

### Schritt 4 — SSH einrichten (Key + Config + Pubkey-Übergabe)

```
bash "$SKILL_DIR/scripts/setup-ssh.sh" --ip <VM_IP> --user <VM_USER> --email <EMAIL>
# Windows: setup-ssh.ps1 -VmIp <IP> -VmUser <USER> -Email <EMAIL>
```

Erzeugt den Ed25519-Key nur, falls keiner existiert (`KEY_EXISTS` →
bestehender Key wird genutzt; will der User explizit einen neuen, erst alten
Key manuell wegsichern, dann `--new-key`/`-NewKey`). Ersetzt den
`Host ki-os-vm`-Block idempotent durch die minimale Fassung und legt den
Public Key in die Zwischenablage (`PUBKEY:`-Zeile).

Dem User den Public Key zeigen und die Übergabe an den Admin anbieten —
fertige Mail-/Slack-Vorlagen: `references/ssh-pubkey-handoff.md`.

### Schritt 5 — Warten auf Admin-Freigabe

Der Admin muss den Key hinterlegt und den User komplett eingerichtet haben
(Workspace, Cockpit-Service, Display-Stack). `AskUserQuestion`:

> „Hat dein Admin bestätigt, dass dein User auf der VM angelegt ist?"
> Optionen: „Ja, kann's testen" | „Noch nicht — pausiere hier"

Bei „Noch nicht": pausieren — `/user-onboarding` später erneut aufrufen, der
Skill ist idempotent und macht bereits Erledigtes nicht kaputt.

### Schritt 6 — Smoketest + VM-Werte holen (ein SSH-Roundtrip)

```
bash "$SKILL_DIR/scripts/get-vm-values.sh"
# Windows: get-vm-values.ps1
```

Liefert `SSH_OK` + `COCKPIT_PORT=` / `NOVNC_PORT=` / `NOVNC_PASS=`. Die
Werte für die nächsten Schritte merken; das **noVNC-Passwort dem User
zeigen** (er gibt es später einmalig im noVNC-Tab ein — gern in den
Passwort-Manager; nirgendwo hinschreiben/loggen).

- `SSH_FAIL` → Fehlerbild nachschlagen: `references/ssh.md` → Smoketest.
- `NOVNC_PORT=MISSING` → Display-Stack noch nicht provisioniert — Admin
  kontaktieren, danach hier weitermachen.

### Schritt 7 — Beide Tunnel-Autostarts einrichten

```
bash "$SKILL_DIR/scripts/setup-tunnels.sh" --novnc-port <NOVNC_PORT> --cockpit-port <COCKPIT_PORT>
# Windows: setup-tunnels.ps1 -NovncPort <NOVNC_PORT> -CockpitPort <COCKPIT_PORT>
```

Ein Aufruf richtet **beide** gehärteten Tunnel ein (idempotent, Windows
zusätzlich self-healing: räumt alt/falsch benannte Tunnel-Tasks auf denselben
Ports inhaltsbasiert weg). Die Argumente sind die **VM-seitigen** Werte aus
Schritt 6 — nicht mit den festen lokalen Ports 6080/3847 verwechseln (falscher
Wert tunnelt auf das Display eines anderen Users!). Härtungs-Hintergrund +
Troubleshooting: `references/tunnels.md`.

### Schritt 8 — Mutagen-Sync einrichten

```
bash "$SKILL_DIR/scripts/setup-mutagen.sh" --vm-user <VM_USER>
# Windows: setup-mutagen.ps1 -VmUser <VM_USER>
```

Installiert Mutagen (macOS: Homebrew; Linux: brew oder GitHub-Release;
Windows: GitHub-Release-Zip mit Download-Retry), richtet den Daemon-Autostart
ein und legt die Session `ki-os` an. `SESSION_EXISTS` ist okay (läuft schon);
weicht die Konfiguration ab (z.B. fehlende lokale Skill-Ansicht auf
macOS/Linux), einmalig mit `--recreate`/`-Recreate` neu anlegen — Dateien
bleiben erhalten. Ignore-Begründung + Konflikt-Semantik + Obsidian:
`references/mutagen.md`. (Windows-Status: Mutagen ist die beschlossene
Architektur, dort aber noch nicht im Kundenbetrieb verifiziert — bei
Problemen an den Admin.)

### Schritt 9 — Claude-Code-Desktop-App vorkonfigurieren

```
bash "$SKILL_DIR/scripts/register-desktop-app.sh" --vm-user <VM_USER>
# Windows: register-desktop-app.ps1 -VmUser <VM_USER>
```

Registriert den SSH-Host `ki-os-vm` in der Desktop-App (`ssh_configs.json`,
macOS/Windows) und den Workspace `ssh:ki-os-vm:/home/<VM_USER>/KI-OS` als
vertrautes Projekt in `~/.claude.json` — die App zeigt die VM dann ohne
Trust-Prompts im Remote-Projekt-Switcher. Danach **Desktop-App komplett
beenden und neu öffnen** (liest `ssh_configs.json` nur beim Start). Linux:
keine Desktop-App — es wird nur `~/.claude.json` geschrieben (gilt für die
Terminal-CLI). Fehlt `~/.claude.json` (WARN): einmalig `claude` starten,
Schritt wiederholen. Hintergrund + manueller Fallback:
`references/desktop-app.md`.

### Schritt 10 — Verifikation

```
bash "$SKILL_DIR/scripts/verify.sh" --vm-user <VM_USER>
# Windows: verify.ps1 -VmUser <VM_USER>
```

Prüft SSH, beide Tunnel, Mutagen-Session, `~/KI-OS` und die
Desktop-App-Einträge (OK/WARN/FAIL pro Komponente). Zusätzlich den User
**aktiv testen lassen**:

1. `http://localhost:6080/vnc.html?resize=scale` öffnen → „Connect" →
   noVNC-Passwort aus Schritt 6 → VM-Desktop sichtbar (leer/grau ist okay,
   solange kein Chrome läuft).
2. Desktop-App (nach Neustart): `ki-os-vm` / `KI-OS` wählen — es darf kein
   Trust-Prompt erscheinen.

Bei FAILs: Troubleshooting-Tabellen in `references/tunnels.md`,
`references/mutagen.md`, `references/ssh.md`.

### Schritt 11 — Abschluss-Zusammenfassung

Statustabelle zeigen (Komponente → Status, aus dem `verify`-Output), dann die
nächsten Schritte:

1. **Claude-Login — ZUERST (einmalig):** im noVNC-Browser
   (`http://localhost:6080/vnc.html?resize=scale`) in **claude.ai** einloggen.
   Der einzige Claude-Auth-Schritt, den der User selbst macht — Voraussetzung
   für Desktop-App, Scheduler und Remote-Control. Die VM richtet daraus
   automatisch beides ein: den Full-Scope-OAuth-Login für
   `claude remote-control` (der `ki-os-relogin`-Watcher heilt bei Ablauf
   selbst) und den long-lived Inference-Token für interaktive/headless
   Sessions (`ki-os-setup-token`, entsteht in wenigen Minuten von selbst).
   Läuft die claude.ai-Session ab, öffnet der Watcher im noVNC-Desktop
   automatisch ein kleines Login-Terminal — dem Link folgen, Code eingeben.
   Details + manueller Fallback: `references/api-keys.md`.
2. **Arbeiten** — primär über die **Desktop-App** (Remote-Projekt `ki-os-vm`
   / `KI-OS`). Fallbacks: `claude.ai/code` im Browser · Terminal:
   `ssh ki-os-vm` → `cd ~/KI-OS && claude` · VS Code Remote-SSH:
   `references/vscode-remote-ssh.md`.
3. **Browser-Logins (einmalig):** im noVNC-Tab in die Zielsysteme einloggen —
   siehe „Browser-Logins & OAuth" unten.
4. **Dateien & Obsidian:** `~/KI-OS` ist der lokale Spiegel — als
   Obsidian-Vault öffnen, im Finder/Explorer nutzen; Änderungen syncen
   automatisch.

---

## Re-Run = Update (Bestands-User)

Ein erneuter `/user-onboarding`-Lauf IST das Update: Die Schritte 4–10
re-deployen alle Komponenten idempotent auf den aktuellen Stand (bestehender
Key bleibt, Tunnel/Tasks werden neu geladen statt dupliziert, die
Mutagen-Session bleibt bestehen). Unter Windows heilt der Lauf dabei
fehlerhaft konfigurierte alte Tunnel-Tasks automatisch (inhaltsbasierter
Cleanup in `setup-tunnels.ps1`). Kein Sonderfall, nichts Spezielles zu tun —
einfach normal durchlaufen lassen.

---

## Browser-Logins & OAuth (Doku für den User)

Alles läuft auf der VM:

- **Browser-Logins (Google, GitHub-Web, CRM, …):** Im noVNC-Tab läuft der
  VM-Chrome mit eigenem Profil. Dort einmalig einloggen — die Sessions
  persistieren auf der VM und stehen dem Agent zur Verfügung. **Keine
  privaten/Banking-Logins** in diesem Profil — der Agent kann auf alles
  zugreifen.
- **OAuth-Flows von CLIs auf der VM** (`gh auth login`, `gws auth login`,
  MCP-OAuth): auf der VM mit dem `ki-os-auth`-Wrapper starten (z.B.
  `ki-os-auth gh auth login`) — der Browser öffnet sich im noVNC-Tab,
  Loopback-Callbacks funktionieren, weil CLI und Browser auf derselben VM
  laufen.
- **Device-/Paste-Code-Flows** (`claude auth login`, `gh` Device-Flow):
  Code + URL erscheinen im Chat/Terminal — die URL im **lokalen** Browser
  öffnen und den Code eingeben. Kein Sonderfall, kein Helper nötig.

---

## Hinweise

- **Idempotent:** Alle Skripte prüfen den Zustand; `ki-os-vm`-Config-Block
  und Autostarts werden bewusst überschrieben/neu geladen, damit Konfig-Drift
  nicht unbemerkt bleibt. Der SSH-Key wird nie ungefragt ersetzt.
- **Sicherheit:** Private Keys nie ausgeben oder loggen. Das noVNC-Passwort
  nur dem User zeigen — nicht in Configs/Logs schreiben. API-Tokens werden in
  diesem Skill nicht angefasst.
- **Windows nativ:** Alle SSH-/Tunnel-Schritte nutzen den nativen
  Windows-OpenSSH (`C:\Windows\System32\OpenSSH\ssh.exe`); die Git-Bash-ssh
  nicht davor in den PATH stellen.
