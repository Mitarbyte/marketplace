---
name: user-onboarding
description: "Lokales Onboarding fuer einen Mitarbeiter, der einen vom Admin bereits auf einer Firmen-VM angelegten KI-OS-Workspace nutzen will. Use when someone says 'KI-OS einrichten', 'vm-zugriff einrichten', 'ssh-key fuer firmen-vm', 'mit der firmen-vm verbinden', 'lokales setup fuer hub-vm', 'novnc-tunnel einrichten', 'vm-browser im browser ansehen', 'cockpit-tunnel einrichten', 'mutagen-sync fuer ki-os', 'ki-os ordner lokal syncen', 'obsidian-vault fuer ki-os', '/user-onboarding'. Also trigger when someone just got their VM-Username + IP from an admin and wants to start using their workspace, or when an existing user wants to refresh/repair their local setup (re-run is the update). Skill macht ausschliesslich LOKALE Schritte ueber parametrisierte Skripte in scripts/: SSH-Key, minimaler ~/.ssh/config-Eintrag, Pflicht-Autostarts (tunnel-Modus: gehaerteter noVNC-Tunnel lokal 6080 + gehaerteter Cockpit-Tunnel lokal 3847 + Mutagen; gateway-Modus: nur Mutagen — noVNC/Cockpit laufen ueber die oeffentlichen Gateway-URLs der VM mit Firmen-Login) sowie die Desktop-App-Vorkonfiguration auf macOS/Windows (SSH-Host ki-os-vm in ssh_configs.json + ~/.claude.json-Workspace-Eintrag). Der SSH-Alias ist fest ki-os-vm und wird nicht abgefragt; den Zugangs-Modus (tunnel|gateway) liest der Skill von der VM. Auf gateway-VMs ist der Skill das OPTIONALE Power-User-Paket (Datei-Sync + Desktop-App) — Browser-Zugang funktioniert dort schon ohne lokales Setup. Der Workspace auf der VM ist bereits vom Admin angelegt und wird hier nicht angefasst; Browser + Logins laufen im VM-Chrome (noVNC-Tab bzw. Gateway-URL). Unterstuetzte Plattformen: macOS, Linux, Windows (nativ ueber PowerShell + Windows-OpenSSH + Scheduled Tasks; WSL2 als Alternative)."
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

**Zwei VM-Modi** (liest der Skill in Schritt 6 von der VM — `ACCESS_MODE`):

- **tunnel (Default):** wie unten beschrieben — drei Pflicht-Autostarts.
- **gateway:** noVNC + Cockpit laufen über öffentliche Gateway-URLs der VM
  („Mit Microsoft/Google anmelden") — der Skill ist dann das **optionale
  Power-User-Paket**: SSH-Key + Mutagen-Sync + Desktop-App, **keine
  Tunnel-Autostarts** (Schritt 7 entfällt; bei Bestands-Setups räumt
  `setup-tunnels --remove` die alten Tunnel ab). Wer nur im Browser
  arbeitet, braucht diesen Skill gar nicht.

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
- **Drei Pflicht-Autostarts, keine Auswahl** (tunnel-Modus) — noVNC-Tunnel,
  Cockpit-Tunnel, Mutagen-Sync werden immer eingerichtet. Backends pro OS:
  LaunchAgents (macOS), systemd-User-Services (Linux), Windows: EIN
  gemeinsamer Scheduled Task `ki-os-vm-watchdog` (Autor `Mitarbyte` +
  Beschreibung), der alle drei Komponenten liveness-guarded am Leben hält.
  **Im gateway-Modus ist nur der Mutagen-Autostart Pflicht** — die beiden
  Tunnel entfallen (Windows: der Watchdog-Task entsteht in der
  Mutagen-only-Variante).
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

Liefert `SSH_OK` + `ACCESS_MODE=` + `COCKPIT_PORT=` / `NOVNC_PORT=` /
`NOVNC_PASS=` (im gateway-Modus zusätzlich `GATEWAY_COCKPIT_URL=` /
`GATEWAY_NOVNC_URL=`). Die Werte für die nächsten Schritte merken.

- **tunnel:** das **noVNC-Passwort dem User zeigen** (er gibt es später
  einmalig im noVNC-Tab ein — gern in den Passwort-Manager; nirgendwo
  hinschreiben/loggen). Es ist dort die einzige Schicht hinter dem Tunnel.
- **gateway:** `NOVNC_PASS=NOT_NEEDED` — es gibt **kein** VNC-Passwort
  (x11vnc läuft mit `-nopw`, ADR § 5.6: Firmen-Login + Gateway-403
  schützen bereits). Nicht nach einem fragen, keins übermitteln.

- `SSH_FAIL` → Fehlerbild nachschlagen: `references/ssh.md` → Smoketest.
- `NOVNC_PORT=MISSING` → Display-Stack noch nicht provisioniert — Admin
  kontaktieren, danach hier weitermachen.
- `GATEWAY_COCKPIT_URL=MISSING` (gateway) → kein Gateway-Mapping für
  diesen User — Admin kontaktieren (`ki-os-fleet vm gateway-grant`).

**`ACCESS_MODE=gateway` → Schritt 7 überspringen** (URLs merken; hatte
der User früher Tunnel eingerichtet, stattdessen einmal
`setup-tunnels.sh --remove` bzw. `setup-tunnels.ps1 -Remove` laufen
lassen — baut die Tunnel-Autostarts ab, Mutagen/SSH bleiben).

### Schritt 7 — Beide Tunnel-Autostarts einrichten (nur tunnel-Modus)

```
bash "$SKILL_DIR/scripts/setup-tunnels.sh" --novnc-port <NOVNC_PORT> --cockpit-port <COCKPIT_PORT>
# Windows: setup-tunnels.ps1 -NovncPort <NOVNC_PORT> -CockpitPort <COCKPIT_PORT>
```

Ein Aufruf richtet **beide** gehärteten Tunnel ein (idempotent, Windows
zusätzlich self-healing: räumt alt/falsch benannte Tunnel-/Daemon-Tasks
inhaltsbasiert weg). Unter Windows entsteht dabei EIN gemeinsamer Task
`ki-os-vm-watchdog`, der auch den Mutagen-Daemon aus Schritt 8 mit überwacht —
Reihenfolge 7 → 8 einhalten. Die Argumente sind die **VM-seitigen** Werte aus
Schritt 6 — nicht mit den festen lokalen Ports 6080/3847 verwechseln (falscher
Wert tunnelt auf das Display eines anderen Users!). Härtungs-Hintergrund +
Troubleshooting: `references/tunnels.md`.

### Schritt 8 — Mutagen-Sync einrichten

```
bash "$SKILL_DIR/scripts/setup-mutagen.sh" --vm-user <VM_USER>
# Windows: setup-mutagen.ps1 -VmUser <VM_USER>
# Windows im gateway-Modus zusätzlich -Gateway anhängen — nur dann darf
# setup-mutagen den Watchdog selbst Mutagen-only anlegen (auf tunnel-VMs würde
# das laufende Alt-Tunnel abräumen):
#   setup-mutagen.ps1 -VmUser <VM_USER> -Gateway
```

Installiert Mutagen (macOS: Homebrew; Linux: brew oder GitHub-Release;
Windows: GitHub-Release-Zip mit Download-Retry), richtet den Daemon-Autostart
ein (Windows: übernimmt der `ki-os-vm-watchdog`-Task aus Schritt 7; fehlt er —
gateway-Modus ohne Tunnel — legt `setup-mutagen.ps1` ihn selbst in der
Mutagen-only-Variante an) und legt die Session `ki-os` an.

Teilst du deinen `~/KI-OS/Workspaces`-Ordner per Bind-Mount mit Kollegen, setzt
das Skript VM-seitig (**alpha**) dessen Gruppe plus `0660`/`0770` — sonst könnten
die anderen deine Mutagen-Neuanlagen nicht lesen/schreiben. Das **erkennt** das
Skript selbst am setgid-Bit des Ordners (Meldung `OK: geteilter
Workspaces-Ordner erkannt`); ohne geteilten Ordner passiert nichts. Nur wenn die
Erkennung per SSH scheitert (`WARN:`) und du teilst, den Schritt mit
`--shared-group <NAME>` bzw. `-SharedGroup <NAME>` wiederholen. **Auf Windows**
kommt zusätzlich
`--symlink-mode=ignore` dazu (der `.claude/skills`-Ignore allein reicht nicht,
`hub/Skills` hat eigene Symlinks) und `MUTAGEN_SSH_PATH` wird auf den nativen
Windows-OpenSSH gesetzt. Begründung zu allen drei: `references/mutagen.md`.

`SESSION_EXISTS` ist okay (läuft schon). Meldet das Skript zusätzlich `DRIFT:`,
weicht die bestehende Session vom Template ab (Ignores, Symlink-Mode und Group
sind bei einer laufenden Session **unveränderlich**) → einmalig mit
`--recreate`/`-Recreate` neu anlegen; Dateien bleiben erhalten. **Vorher
zwingend prüfen**, dass `mutagen sync list ki-os` auf alpha **und** beta die
gleiche Datei-/Verzeichniszahl zeigt — eine Neuanlage startet ohne Ancestor und
spült sonst lokal-only Daten als Neuanlage auf die VM
(`references/mutagen.md` → „Warum `--recreate` bei Divergenz gefährlich ist").

Richtet zusätzlich einen **Session-Watchdog** ein (macOS
LaunchAgent / Linux systemd-Timer, ~2 min; Windows deckt der
`ki-os-vm-watchdog`-Task ab), der eine nach VM-Idle-Suspend in `paused`/`halted`
gelaufene Session automatisch resumt — sonst kämen lokale Skill-Outputs nicht
mehr an, obwohl die VM-Seite gesund ist. Derselbe Watchdog löst zusätzlich
**blockierte VM-Löschungen** auf: räumt ein Agent auf der VM einen Ordner weg,
bleibt er lokal komplett stehen, solange ignorierte Reste darin liegen (auf
macOS legt der Finder überall `.DS_Store` ab) — der Watchdog verschiebt den
Ordner dann komplett nach `~/.local/state/ki-os/sync-trash/<zeitstempel>/`, womit
beide Seiten wieder einig sind und **nichts** verloren geht (auch nicht, was nur
lokal existierte); `.git` fasst er nie an, sondern meldet `SYNC-BLOCK:`. **Der Watchdog heilt aber nur
`paused`/`halted`** — eine Session, die dauerhaft auf `Applying changes` steht
(Transition problems oder toter Agent-Transport), heilt er nicht; ein „laufender"
Watchdog-Task ist also kein Gesundheitsnachweis. Gesund heißt ausschließlich
`Watching for changes` ohne Problems-Block. Ignore-Begründung +
Konflikt-Semantik + Selbstheilung + Recovery + Obsidian:
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
bash "$SKILL_DIR/scripts/verify.sh" --vm-user <VM_USER> --mode <ACCESS_MODE> \
    [--gateway-cockpit-url <URL> --gateway-novnc-url <URL>]
# Windows: verify.ps1 -VmUser <VM_USER> -Mode <ACCESS_MODE> `
#     [-GatewayCockpitUrl <URL> -GatewayNovncUrl <URL>]
```

Prüft SSH, die Zugangswege (tunnel: beide lokalen Tunnel; gateway: die zwei
HTTPS-URLs — 302 zum IdP-Login = OK), Mutagen-Session, `~/KI-OS` und die
Desktop-App-Einträge (OK/WARN/FAIL pro Komponente). Zusätzlich den User
**aktiv testen lassen**:

1. tunnel: `http://localhost:6080/vnc.html?resize=scale` öffnen → „Connect"
   → noVNC-Passwort aus Schritt 6 → VM-Desktop sichtbar (leer/grau ist okay,
   solange kein Chrome läuft). — gateway: `<GATEWAY_NOVNC_URL>` öffnen →
   „Mit Microsoft/Google anmelden" (Firmen-Login) → verbindet automatisch,
   VM-Desktop sichtbar (**kein** Passwort).
2. Desktop-App (nach Neustart): `ki-os-vm` / `KI-OS` wählen — es darf kein
   Trust-Prompt erscheinen.

Bei FAILs: Troubleshooting-Tabellen in `references/tunnels.md`,
`references/mutagen.md`, `references/ssh.md`.

### Schritt 11 — Abschluss-Zusammenfassung

Statustabelle zeigen (Komponente → Status, aus dem `verify`-Output), dann die
nächsten Schritte:

1. **Claude-Login — ZUERST (einmalig):** im noVNC-Browser
   (tunnel: `http://localhost:6080/vnc.html?resize=scale`; gateway:
   `<GATEWAY_NOVNC_URL>`) in **claude.ai** einloggen.
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
   `references/vscode-remote-ssh.md`. Im gateway-Modus zusätzlich immer:
   Cockpit + noVNC direkt über die Gateway-URLs (Firmen-Login), von jedem
   Gerät ohne dieses Setup.
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
fehlerhaft konfigurierte alte Tasks automatisch und konsolidiert
Bestands-Setups mit drei Einzel-Tasks (`ki-os-vm-{novnc,cockpit}-tunnel`,
`mutagen-daemon`) auf den einen `ki-os-vm-watchdog`-Task (inhaltsbasierter
Cleanup in `setup-tunnels.ps1`). Kein Sonderfall, nichts Spezielles zu tun —
einfach normal durchlaufen lassen.

**Wurde die VM inzwischen auf den gateway-Modus umgestellt** (Schritt 6
meldet `ACCESS_MODE=gateway`), räumt der Re-Run die beiden
Tunnel-Autostarts ab (`setup-tunnels.sh --remove` / `-Remove`) und der
User arbeitet fortan über die Gateway-URLs; Mutagen + Desktop-App bleiben
unverändert bestehen.

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
  (nur tunnel-Modus) nur dem User zeigen — nicht in Configs/Logs schreiben; im
  gateway-Modus gibt es keins (`NOVNC_PASS=NOT_NEEDED`, ADR § 5.6), also auch
  nichts zu übermitteln. API-Tokens werden in diesem Skill nicht angefasst.
- **Windows nativ:** Alle SSH-/Tunnel-Schritte nutzen den nativen
  Windows-OpenSSH (`C:\Windows\System32\OpenSSH\ssh.exe`); die Git-Bash-ssh
  nicht davor in den PATH stellen.
