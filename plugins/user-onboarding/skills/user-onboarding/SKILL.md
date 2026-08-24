---
name: user-onboarding
description: "Lokales Onboarding fuer einen Mitarbeiter, der einen vom Admin bereits auf einer Firmen-VM angelegten KI-OS-Workspace nutzen will. Use when someone says 'KI-OS einrichten', 'vm-zugriff einrichten', 'ssh-key fuer firmen-vm', 'mit der firmen-vm verbinden', 'lokales setup fuer hub-vm', 'novnc-tunnel einrichten', 'cockpit-tunnel einrichten', 'mutagen-sync fuer ki-os', 'sync reparieren', 'ki-os ordner lokal syncen', 'obsidian-vault fuer ki-os', '/user-onboarding'. Also trigger when someone just got their VM-Username + IP (or a company login URL) from an admin and wants to start using their workspace, or when an existing user wants to refresh/repair their local setup (re-run is the update). Der Skill fragt als ERSTES den Zugangs-Modus ab und faehrt dann genau einen von zwei Pfaden: gateway (Firmen-Login-URL vom Admin) = SSH-Key, den der User im Cockpit SELBST hinterlegt, plus Desktop-App-Vorkonfiguration — KEINE Tunnel, KEIN Mutagen; tunnel (nur IP + Username) = SSH-Key an den Admin, dazu die drei Pflicht-Autostarts noVNC-Tunnel (lokal 6080), Tunnel zur Agenten-Oberflaeche (Cockpit 3847 bzw. Hermes-Dashboard 9119 je nach Engine) und Mutagen-Sync. Alles laeuft ueber fertige, parametrisierte Skripte in scripts/. Der SSH-Alias ist fest ki-os-vm. Der Workspace auf der VM ist bereits vom Admin angelegt und wird hier nicht angefasst; Browser + Logins laufen im VM-Chrome (noVNC-Tab bzw. Gateway-URL). Plattformen: macOS, Linux, Windows (nativ ueber PowerShell + Windows-OpenSSH + Scheduled Tasks; WSL2 als Alternative)."
---

## Was dieser Skill macht

Richtet auf dem lokalen Gerät (macOS/Linux/Windows) den Zugang zur bereits
vom Admin eingerichteten Firmen-VM ein. **Der Zugangs-Modus entscheidet über
den ganzen Ablauf und wird als erstes abgefragt** (Schritt 3):

| | **gateway** (Regelfall) | **tunnel** |
|---|---|---|
| Woran erkennbar | Admin schickte eine **URL** (`https://<name>-cockpit.…` / `…-agent.…`) + Firmen-Login | Admin schickte nur **IP + Username** |
| SSH-Key | User trägt ihn **selbst im Cockpit** ein (System-Tab) | geht **an den Admin** |
| Tunnel-Autostarts | **entfallen** — noVNC/Cockpit laufen über die Gateway-URLs | noVNC (lokal `6080`) + Agenten-Oberfläche (`3847` claude / `9119` hermes) |
| Mutagen-Sync | **entfällt** — Dateien über Cockpit-Explorer bzw. den Cloud-Client der Firma | Pflicht (`~/KI-OS` ↔ VM), außer `HUB_BACKEND=cloud` |
| Desktop-App | ja (nur `engine=claude`) | ja (nur `engine=claude`) |

**Die gesamte Mechanik liegt in fertigen, parametrisierten Skripten unter
`scripts/`** — der Skill orchestriert nur: Inputs einsammeln, Skripte mit
Argumenten aufrufen, Output-Marker auswerten, User führen. Die Skripte NICHT
im Chat nachbauen oder abwandeln; das Warum steht in `references/`.

**Nicht-Ziele:** VM-seitiges Setup (Admin-Sache), lokale Hub-Klone,
Browser-Logins (macht der User selbst im VM-Chrome).

**Zweite Achse: `ENGINE`** (`claude` | `hermes`, liest Schritt 7 von der VM,
wird nie abgefragt):

- **claude:** Cockpit als Oberfläche, Claude-Code-Desktop-App als Arbeitszugang.
- **hermes:** **kein Cockpit** — Oberfläche ist das Hermes-Dashboard; im
  tunnel-Modus wird lokal `9119` getunnelt statt `3847`, Schritt 10
  (Claude-Desktop-App) entfällt.

## Konventionen

- **SSH-Alias fest `ki-os-vm`** — wird nie abgefragt. Alle Service-/Task-Namen
  und Desktop-App-Einträge leiten sich daraus ab.
- **Tunnel laufen als eigene Prozesse, nicht in der SSH-Config** — die
  `~/.ssh/config` enthält keine Forward-Zeilen, kein ControlMaster
  (`references/ssh.md`).
- **Autostart-Backends:** LaunchAgents (macOS), systemd-User-Services (Linux),
  Windows: EIN gemeinsamer Scheduled Task `ki-os-vm-watchdog`, der alle
  Komponenten liveness-guarded am Leben hält.
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
(User startet `wsl` und durchläuft den Linux-Pfad; systemd muss aktiv sein —
`/etc/wsl.conf`: `[boot]\nsystemd=true`, danach `wsl --shutdown`).

### Schritt 2 — Vorbedingungen (nur natives Windows)

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\check-prereqs.ps1"
```

Prüft/installiert Windows-OpenSSH-Client (Install braucht Admin — bei
`MISSING_ADMIN` den User eine Admin-PowerShell öffnen lassen) und Git for
Windows (Pflicht für Claude Code auf nativem Windows). macOS/Linux: überspringen.

### Schritt 3 — Zugangs-Modus bestimmen (die Weiche)

`AskUserQuestion` — eine Frage, die Modus **und** den Weg für den SSH-Key
festlegt:

> „Was hast du vom Admin bekommen?"
> - **„Eine Cockpit-Adresse"** (`https://<name>-cockpit.…`, Login mit dem
>   Firmen-Konto) → **gateway**, Key per Self-Service
> - **„Eine Agent-Adresse"** (`https://<name>-agent.…`) → **gateway** auf einer
>   Hermes-VM, Key über den Admin (dort gibt es kein Cockpit)
> - **„Nur IP + Username"** → **tunnel**, Key über den Admin
> - **„Weiß ich nicht"** → wie „Nur IP + Username" behandeln; Schritt 7 liest
>   den echten Modus von der VM und korrigiert.

Ergebnis merken als `MODE` (`gateway`|`tunnel`). **`MODE=gateway` → Schritte 8
und 9 entfallen komplett.**

### Schritt 4 — User-Inputs sammeln

`AskUserQuestion`: **VM-Public-IP** und **VM-Username** (vom Admin), **Email**
für den Key-Kommentar (Default: `git config --global user.email`). Keine
weiteren Fragen.

### Schritt 5 — SSH-Key + Config

```
bash "$SKILL_DIR/scripts/setup-ssh.sh" --ip <VM_IP> --user <VM_USER> --email <EMAIL>
# Windows: setup-ssh.ps1 -VmIp <IP> -VmUser <USER> -Email <EMAIL>
```

Erzeugt den Ed25519-Key nur, falls keiner existiert (`KEY_EXISTS` →
bestehender Key wird genutzt; will der User explizit einen neuen, erst den
alten wegsichern, dann `--new-key`/`-NewKey`). Schreibt den `Host ki-os-vm`-Block
idempotent und legt den Public Key in die Zwischenablage (`PUBKEY:`-Zeile).

### Schritt 6 — Public Key auf der VM hinterlegen

Den Key dem User zeigen (er liegt auch in der Zwischenablage). Der Weg hängt
an der Antwort aus Schritt 3:

**gateway + Cockpit-Adresse → Self-Service, kein Warten:**

1. Cockpit-URL im Browser öffnen, mit dem **Firmen-Konto** anmelden.
   (Funktioniert der Login, ist der User auf der VM bereits angelegt.)
2. Tab **System** → Karte **„SSH-Zugang"** → Pubkey einfügen (die Zeile beginnt
   mit `ssh-ed25519`) → **„Key hinterlegen"**. Das Feld nimmt nur den
   öffentlichen Schlüssel — niemals die private Key-Datei hochladen.
3. Direkt weiter mit Schritt 7.

Fehlt die Karte „SSH-Zugang", ist das Cockpit der VM zu alt → Admin-Weg unten,
und dem Admin `ki-os-fleet update` ans Herz legen.

**Sonst (Agent-Adresse, tunnel, unklar) → Admin-Weg:** Übergabe anbieten,
fertige Mail-/Slack-Vorlagen in `references/ssh-pubkey-handoff.md`. Dann per
`AskUserQuestion` klären: „Hat dein Admin bestätigt, dass dein User auf der VM
angelegt ist?" — bei „Noch nicht" hier pausieren; `/user-onboarding` später
erneut aufrufen (idempotent).

### Schritt 7 — Smoketest + VM-Werte (ein SSH-Roundtrip)

```
bash "$SKILL_DIR/scripts/get-vm-values.sh"
# Windows: get-vm-values.ps1
```

Liefert `SSH_OK` + `ACCESS_MODE=` + `ENGINE=` + `HUB_BACKEND=` (+
`COMPANY_LOCAL=` nur auf cloud) + `AGENT_PORT=` / `COCKPIT_PORT=` /
`NOVNC_PORT=` / `NOVNC_PASS=`, im gateway-Modus zusätzlich
`GATEWAY_COCKPIT_URL=` / `GATEWAY_NOVNC_URL=` (/ `GATEWAY_AGENT_URL=` auf
hermes). Werte merken.

- **`ACCESS_MODE` ist die Wahrheit** — weicht es von der Antwort aus Schritt 3
  ab, gilt der VM-Wert: `MODE` überschreiben, den User kurz informieren und
  entsprechend weiterfahren.
- **tunnel:** das **noVNC-Passwort dem User zeigen** (einmalig im noVNC-Tab
  einzugeben, gern in den Passwort-Manager; nirgends hinschreiben/loggen).
- **gateway:** `NOVNC_PASS=NOT_NEEDED` — es gibt **kein** VNC-Passwort
  (x11vnc läuft mit `-nopw`, ADR § 5.6). Nicht danach fragen, keins übermitteln.
- `SSH_FAIL` → `references/ssh.md` → Smoketest.
- `NOVNC_PORT=MISSING` → Display-Stack nicht provisioniert → Admin.
- `GATEWAY_*_URL=MISSING` → kein Gateway-Mapping für diesen User → Admin
  (`ki-os-fleet vm gateway-grant`).

**`MODE=gateway` → weiter mit Schritt 10.** Hatte der User früher Tunnel
eingerichtet: einmal `setup-tunnels.sh --remove` bzw. `-Remove` laufen lassen
(baut die Tunnel-Autostarts ab, SSH bleibt). Eine bestehende Mutagen-Session
bleibt unangetastet — sie wird nicht mehr eingerichtet, aber auch nicht
abgeräumt (das entscheidet der User bzw. der Admin).

**`HUB_BACKEND=cloud` (tunnel-Modus) → Schritt 9 überspringen:** die geteilten
Ordner kommen über SharePoint/Google Drive der Firma; Mutagen wäre eine zweite
Sync-Engine auf denselben Bytes (Konfliktkopien). In Schritt 11
`--hub-backend cloud` mitgeben.

### Schritt 8 — Tunnel-Autostarts *(nur tunnel)*

```
# engine=claude:
bash "$SKILL_DIR/scripts/setup-tunnels.sh" --novnc-port <NOVNC_PORT> --cockpit-port <COCKPIT_PORT>
# Windows: setup-tunnels.ps1 -NovncPort <NOVNC_PORT> -CockpitPort <COCKPIT_PORT>

# engine=hermes (zweiter Tunnel geht auf das Hermes-Dashboard, lokal 9119):
bash "$SKILL_DIR/scripts/setup-tunnels.sh" --engine hermes --novnc-port <NOVNC_PORT> --agent-port <AGENT_PORT>
# Windows: setup-tunnels.ps1 -Engine hermes -NovncPort <NOVNC_PORT> -AgentPort <AGENT_PORT>
```

Ein Aufruf richtet **beide** gehärteten Tunnel ein (idempotent; Windows
zusätzlich self-healing: räumt alt/falsch benannte Tasks inhaltsbasiert weg und
legt den gemeinsamen `ki-os-vm-watchdog` an). Die Argumente sind die
**VM-seitigen** Ports aus Schritt 7 — nicht mit den festen lokalen Ports
6080/3847/9119 verwechseln (ein falscher Wert tunnelt auf das Display eines
anderen Users!). Härtung + Troubleshooting: `references/tunnels.md`.

### Schritt 9 — Mutagen-Sync *(nur tunnel, nur `HUB_BACKEND=git`)*

```
bash "$SKILL_DIR/scripts/setup-mutagen.sh" --vm-user <VM_USER>
# Windows: setup-mutagen.ps1 -VmUser <VM_USER>
```

Installiert Mutagen, richtet den Daemon-Autostart ein und legt die Session
`ki-os` an (`VM:~/KI-OS` ↔ lokal `~/KI-OS`, two-way, VM gewinnt Konflikte).
Dazu einen **Session-Watchdog**, der nach VM-Idle-Suspend `paused`/`halted`
gelaufene Sessions resumt und blockierte VM-Löschungen auflöst (verschiebt sie
nach `~/.local/state/ki-os/sync-trash/`, `.git` fasst er nie an). Geteilte
`Workspaces`-Ordner (Bind-Mount mit Kollegen) erkennt das Skript am setgid-Bit
selbst; nur bei `WARN:` den Lauf mit `--shared-group <NAME>` wiederholen.

Marker auswerten: `SESSION_EXISTS` ist okay. `DRIFT:` = die laufende Session
weicht vom Template ab (Ignores/Symlink-Mode/Group sind unveränderlich) →
einmalig `--recreate`/`-Recreate`. **Vorher zwingend prüfen**, dass
`mutagen sync list ki-os` auf alpha **und** beta die gleiche Datei-/
Verzeichniszahl zeigt — eine Neuanlage startet ohne Ancestor und spült sonst
lokal-only Daten als Neuanlage auf die VM (`references/mutagen.md` → „Warum
`--recreate` bei Divergenz gefährlich ist").

Gesund heißt ausschließlich `Watching for changes` **ohne** Problems-Block; ein
laufender Watchdog ist kein Gesundheitsnachweis (er heilt nur `paused`/`halted`).
Ignores, Konflikt-Semantik, Recovery, Obsidian: `references/mutagen.md`.
(Windows: Mutagen ist die beschlossene Architektur, dort aber noch nicht im
Kundenbetrieb verifiziert — bei Problemen an den Admin.)

### Schritt 10 — Desktop-App vorkonfigurieren

**`ENGINE=hermes` → überspringen.** Es gibt lokal nichts zu registrieren: die
**Hermes-Desktop-App** wird als „Remote gateway" mit URL + **Session-Token**
verbunden (Token vom Admin: `ki-os-fleet vm hermes-token --user <VM_USER>`);
URL = die öffentliche `…-agent.…`-Adresse (gateway) bzw.
`http://127.0.0.1:9119` durch den Tunnel (tunnel). Token wie ein Passwort
behandeln. Details + Vorlage: `references/hermes-desktop-app.md`.

Für `ENGINE=claude`:

```
bash "$SKILL_DIR/scripts/register-desktop-app.sh" --vm-user <VM_USER>
# Windows: register-desktop-app.ps1 -VmUser <VM_USER>
```

Registriert den SSH-Host `ki-os-vm` (`ssh_configs.json`, macOS/Windows) und den
Workspace `ssh:ki-os-vm:/home/<VM_USER>/KI-OS` als vertrautes Projekt in
`~/.claude.json` — die App zeigt die VM dann ohne Trust-Prompts im
Remote-Projekt-Switcher. Danach **Desktop-App komplett beenden und neu öffnen**
(liest `ssh_configs.json` nur beim Start). Linux: keine Desktop-App, es wird nur
`~/.claude.json` geschrieben (gilt für die Terminal-CLI). Fehlt `~/.claude.json`
(WARN): einmalig `claude` starten, Schritt wiederholen. Hintergrund:
`references/desktop-app.md`.

### Schritt 11 — Verifikation

```
bash "$SKILL_DIR/scripts/verify.sh" --vm-user <VM_USER> --mode <MODE> \
    --engine <ENGINE> --hub-backend <HUB_BACKEND> \
    [--gateway-cockpit-url <URL> --gateway-novnc-url <URL> --gateway-agent-url <URL>]
# Windows: verify.ps1 -VmUser <VM_USER> -Mode <MODE> -Engine <ENGINE> `
#     -HubBackend <HUB_BACKEND> `
#     [-GatewayCockpitUrl <URL> -GatewayNovncUrl <URL> -GatewayAgentUrl <URL>]
```

Prüft SSH, die Zugangswege (tunnel: beide lokalen Tunnel; gateway: die zwei
HTTPS-URLs — 302/401/403 zum IdP-Login = OK, ein **200 unauthentifiziert** ist
ein Auth-Bypass und gehört sofort an den Admin) und die Desktop-App-Einträge.
Die Mutagen-Checks laufen nur im tunnel-Modus mit `--hub-backend git`; sonst
SKIP. Im tunnel-Modus meldet der Verify zusätzlich, was ein „laufender" Sync
verdeckt: **Konflikte**, **Transition problems** und offene
**Watchdog-Meldungen** (`SYNC-FAIL`/`SYNC-BLOCK`).

Zusätzlich den User **aktiv testen lassen**:

1. gateway: `<GATEWAY_NOVNC_URL>` öffnen → „Mit Microsoft/Google anmelden" →
   VM-Desktop erscheint (**kein** Passwort). — tunnel:
   `http://localhost:6080/vnc.html?resize=scale` → „Connect" → noVNC-Passwort
   aus Schritt 7 → VM-Desktop (leer/grau ist okay, solange kein Chrome läuft).
2. Desktop-App (nach Neustart): `ki-os-vm` / `KI-OS` wählen — es darf kein
   Trust-Prompt erscheinen.

Bei FAILs: `references/tunnels.md`, `references/mutagen.md`, `references/ssh.md`.

### Schritt 12 — Abschluss

Statustabelle aus dem `verify`-Output zeigen, dann die nächsten Schritte:

**`ENGINE=claude`:**

1. **Claude-Login — ZUERST (einmalig):** im VM-Browser (gateway:
   `<GATEWAY_NOVNC_URL>`; tunnel: `http://localhost:6080/vnc.html?resize=scale`)
   in **claude.ai** einloggen. Der einzige Claude-Auth-Schritt, den der User
   selbst macht — Voraussetzung für Desktop-App, Scheduler und Remote-Control.
   Die VM baut daraus automatisch beides: den Full-Scope-OAuth-Login für
   `claude remote-control` (`ki-os-relogin`-Watcher heilt bei Ablauf selbst) und
   den long-lived Inference-Token (`ki-os-setup-token`, entsteht binnen Minuten).
   Läuft die Session ab, öffnet der Watcher im VM-Desktop ein kleines
   Login-Terminal — Link folgen, Code eingeben. Details:
   `references/api-keys.md`.
2. **Arbeiten** — primär **Desktop-App** (Remote-Projekt `ki-os-vm` / `KI-OS`).
   Fallbacks: `claude.ai/code` · `ssh ki-os-vm` → `cd ~/KI-OS && claude` ·
   VS Code Remote-SSH (`references/vscode-remote-ssh.md`). gateway zusätzlich:
   Cockpit + noVNC über die Gateway-URLs, von jedem Gerät ohne lokales Setup.
3. **Browser-Logins (einmalig):** siehe unten.
4. **Dateien:** gateway → Cockpit-Explorer bzw. der Cloud-Client der Firma;
   tunnel → `~/KI-OS` als lokaler Spiegel (Obsidian-Vault, Finder/Explorer).

**`ENGINE=hermes`:**

1. **Browser-Logins (einmalig):** siehe unten. Einen Claude-/Modell-Login gibt
   es hier **nicht** — die Provider-Anmeldung hat der Admin eingerichtet.
2. **Arbeiten** — **Agent-Dashboard** (gateway: `<GATEWAY_AGENT_URL>`; tunnel:
   `http://localhost:9119`) oder die **Hermes-Desktop-App** (Schritt 10).
3. **Geplante Aufgaben:** Scheduler im Dashboard bzw. `hermes cron` auf der VM
   — nicht `mitarbyte scheduler` (Claude-only).
4. **Dateien:** wie oben.

---

## Re-Run = Update (Bestands-User)

Ein erneuter Lauf IST das Update: alle Schritte re-deployen idempotent
(bestehender Key bleibt, Tunnel/Tasks werden neu geladen statt dupliziert, die
Mutagen-Session bleibt bestehen). Unter Windows heilt der Lauf fehlerhaft
konfigurierte Alt-Tasks automatisch.

**Wurde die VM inzwischen auf gateway umgestellt** (Schritt 7 meldet
`ACCESS_MODE=gateway`), räumt der Re-Run die Tunnel-Autostarts ab
(`setup-tunnels.sh --remove` / `-Remove`); eine vorhandene Mutagen-Session
bleibt unangetastet, wird aber nicht mehr gepflegt.

## Schnellpfad: nur Mutagen (Bestands-Sync reparieren)

Nur für **tunnel-Setups mit `HUB_BACKEND=git`** bzw. eine bestehende Session,
die repariert werden soll („Sync kaputt", „KI-OS-Ordner syncen"). Neue
gateway-Setups bekommen keinen Mutagen-Sync mehr. Voraussetzung:
`ssh -o BatchMode=yes -o ConnectTimeout=10 ki-os-vm true` → Exit 0 (sonst
zuerst Schritte 4–6).

```
bash "$SKILL_DIR/scripts/setup-mutagen.sh"
# Windows: setup-mutagen.ps1
```

Ohne Argumente: VM-User und Shared-Group erkennt das Skript in EINEM
SSH-Roundtrip selbst. Danach die Marker wie in Schritt 9 auswerten und prüfen:
`mutagen sync list ki-os` → `Watching for changes` ohne Problems-Block = gesund.

---

## Browser-Logins & OAuth (Doku für den User)

Alles läuft auf der VM:

- **Browser-Logins (Google, GitHub-Web, CRM, …):** Im VM-Chrome (noVNC-Tab bzw.
  Gateway-noVNC-URL) einmalig einloggen — die Sessions persistieren auf der VM
  und stehen dem Agent zur Verfügung. **Keine privaten/Banking-Logins** in
  diesem Profil — der Agent kann auf alles zugreifen.
- **OAuth-Flows von CLIs auf der VM** (`gh auth login`, `gws auth login`,
  MCP-OAuth): auf der VM mit dem `ki-os-auth`-Wrapper starten (z.B.
  `ki-os-auth gh auth login`) — der Browser öffnet sich im noVNC-Tab,
  Loopback-Callbacks funktionieren, weil CLI und Browser auf derselben VM laufen.
- **Device-/Paste-Code-Flows** (`claude auth login`, `gh` Device-Flow): Code +
  URL erscheinen im Chat/Terminal — URL im **lokalen** Browser öffnen, Code
  eingeben.

## Hinweise

- **Idempotent:** Alle Skripte prüfen den Zustand; `ki-os-vm`-Config-Block und
  Autostarts werden bewusst überschrieben/neu geladen, damit Konfig-Drift nicht
  unbemerkt bleibt. Der SSH-Key wird nie ungefragt ersetzt.
- **Sicherheit:** Private Keys nie ausgeben oder loggen. Das noVNC-Passwort
  (nur tunnel) nur dem User zeigen, nicht in Configs/Logs schreiben. API-Tokens
  fasst dieser Skill nicht an.
- **Windows nativ:** Alle SSH-/Tunnel-Schritte nutzen den nativen
  Windows-OpenSSH (`C:\Windows\System32\OpenSSH\ssh.exe`); die Git-Bash-ssh
  nicht davor in den PATH stellen.
