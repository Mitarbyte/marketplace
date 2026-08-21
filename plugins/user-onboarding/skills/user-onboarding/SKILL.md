---
name: user-onboarding
description: "Lokales Onboarding fuer einen Mitarbeiter, der einen vom Admin bereits auf einer Firmen-VM angelegten KI-OS-Workspace nutzen will. Use when someone says 'KI-OS einrichten', 'vm-zugriff einrichten', 'ssh-key fuer firmen-vm', 'mit der firmen-vm verbinden', 'lokales setup fuer hub-vm', 'novnc-tunnel einrichten', 'vm-browser im browser ansehen', 'cockpit-tunnel einrichten', 'mutagen-sync fuer ki-os', 'nur mutagen einrichten', 'sync reparieren', 'ki-os ordner lokal syncen', 'obsidian-vault fuer ki-os', '/user-onboarding'. Also trigger when someone just got their VM-Username + IP from an admin and wants to start using their workspace, or when an existing user wants to refresh/repair their local setup (re-run is the update). Skill macht ausschliesslich LOKALE Schritte ueber parametrisierte Skripte in scripts/: SSH-Key, minimaler ~/.ssh/config-Eintrag, Pflicht-Autostarts (tunnel-Modus: gehaerteter noVNC-Tunnel lokal 6080 + gehaerteter Tunnel zur Agenten-Oberflaeche — Cockpit lokal 3847 bzw. Hermes-Dashboard lokal 9119 je nach Engine der VM — + Mutagen; gateway-Modus: nur Mutagen, alles andere laeuft ueber die oeffentlichen Gateway-URLs der VM mit Firmen-Login) sowie auf engine=claude die Desktop-App-Vorkonfiguration auf macOS/Windows (SSH-Host ki-os-vm in ssh_configs.json + ~/.claude.json-Workspace-Eintrag); auf engine=hermes entfaellt sie, dort wird die Hermes-Desktop-App mit URL + Session-Token verbunden. Der SSH-Alias ist fest ki-os-vm und wird nicht abgefragt; Zugangs-Modus (tunnel|gateway) UND Engine (claude|hermes) liest der Skill von der VM. Auf gateway-VMs ist der Skill das OPTIONALE Power-User-Paket (Datei-Sync + Desktop-App) — Browser-Zugang funktioniert dort schon ohne lokales Setup. Der Workspace auf der VM ist bereits vom Admin angelegt und wird hier nicht angefasst; Browser + Logins laufen im VM-Chrome (noVNC-Tab bzw. Gateway-URL). Unterstuetzte Plattformen: macOS, Linux, Windows (nativ ueber PowerShell + Windows-OpenSSH + Scheduled Tasks; WSL2 als Alternative)."
---

## Was dieser Skill macht

Richtet auf dem lokalen macOS-/Linux-/Windows-Gerät des Mitarbeiters alles
ein, damit er auf seiner vom Admin angelegten VM produktiv arbeiten kann:

1. SSH-Key + minimaler `~/.ssh/config`-Eintrag (fester Alias `ki-os-vm`) —
   Public Key geht an den Admin
2. **Pflicht-Autostart 1:** gehärteter SSH-Tunnel zum noVNC
   (lokal `6080` → VM `<NOVNC_PORT>`) — VM-Browser live unter
   `http://localhost:6080/vnc.html?resize=scale`
3. **Pflicht-Autostart 2:** gehärteter SSH-Tunnel zur Agenten-Oberfläche —
   je nach **Engine** der VM (`ENGINE` aus Schritt 6):
   `claude` → Cockpit (lokal `3847` → VM `<COCKPIT_PORT>`),
   `hermes` → Hermes-Dashboard (lokal `9119` → VM `<AGENT_PORT>`)
4. **Pflicht-Autostart 3:** Mutagen-Daemon + Sync-Session `ki-os`
   (`VM:~/KI-OS` ↔ lokal `~/KI-OS`, two-way, VM gewinnt Konflikte)
5. Desktop-App vorkonfigurieren — **nur auf `engine=claude`**: SSH-Host in
   `ssh_configs.json` + vertrauter Workspace in `~/.claude.json` (macOS/Windows).
   Auf `engine=hermes` entfällt der Schritt: die **Hermes-Desktop-App**
   verbindet sich mit URL + **Session-Token** (vom Admin:
   `ki-os-fleet vm hermes-token --user <du>`), es gibt lokal nichts zu
   registrieren.
6. Verifikation aller Komponenten

**Die gesamte Mechanik liegt in fertigen, parametrisierten Skripten unter
`scripts/`** — der Skill orchestriert nur: Inputs einsammeln, Skripte mit
Argumenten aufrufen, Output-Marker auswerten, User führen. Die Skripte NICHT
im Chat nachbauen oder abwandeln; bei Problemen erklären die
`references/`-Dokumente das Warum.

**Nicht-Ziele:** VM-seitiges Setup (Admin-Sache), lokale Hub-Klone (lokal
gibt es nur die Mutagen-Kopie `~/KI-OS`), Browser-Logins (macht der User
später selbst im noVNC-Tab).

**Zwei Achsen, die der Skill in Schritt 6 von der VM liest** — `ACCESS_MODE`
(wie du reinkommst) und `ENGINE` (welcher Agent drin läuft). Beide sind
unabhängig; der Skill fragt nichts davon ab.

**Engine** (`claude` | `hermes`, Default `claude`):

- **claude:** Cockpit als Oberfläche (Scheduler, Token-Usage, Skills),
  Claude-Code-Desktop-App als Arbeitszugang.
- **hermes:** **kein Cockpit** — die Oberfläche ist das Hermes-Dashboard
  (Scheduler, Sessions, Memory bringt Hermes selbst mit). Im tunnel-Modus wird
  lokal `9119` getunnelt statt `3847`; Schritt 9 (Claude-Desktop-App) entfällt.
  Hintergrund: [`docs/features/hermes/plan.md`](../../../docs/features/hermes/plan.md) § 8.

**Zugangs-Modus:**

- **tunnel (Default):** wie unten beschrieben — drei Pflicht-Autostarts.
- **gateway:** noVNC + Agenten-Oberfläche laufen über öffentliche Gateway-URLs der VM
  („Mit Microsoft/Google anmelden") — der Skill ist dann das **optionale
  Power-User-Paket**: SSH-Key + Mutagen-Sync + Desktop-App, **keine
  Tunnel-Autostarts** (Schritt 7 entfällt; bei Bestands-Setups räumt
  `setup-tunnels --remove` die alten Tunnel ab). Wer nur im Browser
  arbeitet, braucht diesen Skill gar nicht.

**Hub-Backend (`HUB_BACKEND` aus get-vm-values):**

- **git (Default):** Firmenwissen ist ein GitHub-Klon unter `hub/`; der
  Workspace kommt per Mutagen aufs Gerät — wie unten beschrieben.
- **cloud:** Das Firmenwissen (`<Firmenname>/`) und `Geteilte-Arbeitsplaetze/`
  synchronisieren direkt mit SharePoint/Google Drive der Firma — **Mutagen
  entfällt komplett** (Schritt 8 überspringen): die geteilten Ordner liegen
  über den normalen Cloud-Client der Firma ohnehin auf jedem Gerät, eine
  zweite Sync-Engine auf denselben Bytes würde nur Konfliktkopien erzeugen.
  Pflicht bleiben SSH-Key + (tunnel-Modus) die Tunnel-Autostarts; optional
  die Desktop-App. Dateizugriff sonst: Cloud-Web/Client + Cockpit-Explorer
  bzw. Hermes-Dashboard. Läuft auf dem Gerät noch eine alte
  Mutagen-Session, beim Re-Run auf DRIFT achten (die neuen Ignores
  verhindern Doppel-Sync) oder sie mit `mutagen sync terminate ki-os`
  abbauen.

---

## Architektur in 30 Sekunden

Auf der VM läuft pro Mitarbeiter (vom Admin provisioniert): ein eigenes
virtuelles Display mit **headed Chrome** (darin alle Browser-Logins, der
Agent-Browser live sichtbar), **noVNC** auf `127.0.0.1:<NOVNC_PORT>`
(passwortgeschützt), die **Agenten-Oberfläche** (engine=claude: Cockpit auf
`127.0.0.1:<COCKPIT_PORT>` — Scheduler, Token-Usage, Skills; engine=hermes:
Hermes-Dashboard auf `127.0.0.1:<AGENT_PORT>`) und der **Workspace**
`/home/<VM_USER>/KI-OS` (normaler Ordner, Hub als Git-Klon unter `hub/`).

Lokal richtet dieser Skill nur drei dauerhafte Verbindungen ein:

| Verbindung | Lokal | VM | Zweck |
|---|---|---|---|
| noVNC-Tunnel | `localhost:6080` | `127.0.0.1:<NOVNC_PORT>` | VM-Browser ansehen + bedienen |
| Cockpit-Tunnel *(engine=claude)* | `localhost:3847` | `127.0.0.1:<COCKPIT_PORT>` | Cockpit-Web-UI |
| Agent-Tunnel *(engine=hermes)* | `localhost:9119` | `127.0.0.1:<AGENT_PORT>` | Hermes-Dashboard (auch für die Hermes-Desktop-App) |
| Mutagen-Sync | `~/KI-OS` | `/home/<VM_USER>/KI-OS` | Workspace als lokaler Ordner (Obsidian, Finder/Explorer) |

Die lokalen Ports sind für ALLE Mitarbeiter gleich (jeder hat seinen eigenen
Laptop); nur die VM-seitigen Ports sind pro User verschieden. Primärer
Arbeitszugang auf **engine=claude** ist die Claude-Code-Desktop-App; Fallbacks:
claude.ai/code, `ssh` + `claude` im Terminal, VS Code Remote-SSH
(`references/vscode-remote-ssh.md`). Auf **engine=hermes** ist es das
Hermes-Dashboard im Browser bzw. die Hermes-Desktop-App (Remote gateway).

## Konventionen

- **SSH-Alias fest `ki-os-vm`** — wird nie abgefragt (jeder Mitarbeiter hat
  genau eine Firmen-VM). Alle Service-Namen (LaunchAgent-Labels, Unit-/
  Task-Namen) und die Desktop-App-Einträge leiten sich daraus ab.
- **Drei Pflicht-Autostarts, keine Auswahl** (tunnel-Modus) — noVNC-Tunnel,
  Tunnel zur Agenten-Oberfläche (Cockpit bzw. Hermes-Dashboard), Mutagen-Sync
  werden immer eingerichtet. Backends pro OS:
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

## Schnellpfad: Nur Mutagen (Sync einrichten oder reparieren)

Will der User **nur den Datei-Sync** (typisch: „nur mutagen", „Sync
kaputt/reparieren", „KI-OS-Ordner lokal syncen", gateway-VM ohne
Tunnel-Bedarf), NICHT den vollen Ablauf fahren. **Zuerst `HUB_BACKEND`
prüfen** (get-vm-values): auf `cloud` gibt es keinen Mutagen-Sync — dem User
erklären, dass die geteilten Ordner über SharePoint/Google Drive der Firma
kommen, und hier stoppen. Einzige Voraussetzung sonst ist ein
funktionierender SSH-Zugang: `ssh -o BatchMode=yes -o ConnectTimeout=10
ki-os-vm true` → Exit 0. Schlägt das fehl, fehlt das SSH-Setup → Schritte 3–5
zuerst, dann hierher zurück.

```
bash "$SKILL_DIR/scripts/setup-mutagen.sh"
# Windows: setup-mutagen.ps1
```

Keine Argumente, keine Rückfragen nötig: VM-User **und** Shared-Group erkennt
das Skript selbst in EINEM SSH-Roundtrip (`--vm-user`/`-VmUser` nur mitgeben,
wenn SSH gerade down ist und die Session neu angelegt werden muss). Unter
Windows richtet das Skript den Daemon-Autostart auch ohne Schritt 7 selbst
ein: fehlt der `ki-os-vm-watchdog`-Task, entsteht er **additiv Mutagen-only**
(`setup-tunnels.ps1 -EnsureMutagen` — räumt nichts ab, Alt-Tunnel bleiben
unangetastet; ein späterer voller Schritt-7-Lauf erweitert denselben Task um
die Tunnel).

Danach die Output-Marker wie in Schritt 8 auswerten (`SESSION_*`, `DRIFT:` →
ggf. `--recreate` mit den dortigen Vorsichtsregeln) und kurz prüfen:
`mutagen sync list ki-os` → `Watching for changes` ohne Problems-Block =
gesund. Schritte 7 und 9–10 entfallen in diesem Pfad komplett.

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

Dem User den Public Key zeigen (liegt jetzt auch in der Zwischenablage) —
wie er auf die VM kommt, entscheidet Schritt 5.

### Schritt 5 — Key auf der VM hinterlegen (Self-Service oder Admin)

Der Pubkey muss in die `authorized_keys` des VM-Users. Es gibt zwei Wege;
welcher gilt, verrät die Übergabe-Nachricht des Admins. `AskUserQuestion`:

> „Was hast du vom Admin bekommen: eine **Cockpit-Adresse**
> (`https://<name>-cockpit.…`, Login mit deinem Firmen-Konto), eine
> **Agent-Adresse** (`https://<name>-agent.…`) oder keins von beidem?"
> Optionen: „Cockpit-Adresse" | „Agent-Adresse" | „Nein / weiß nicht"

**„Agent-Adresse" → Admin-Weg (Hermes-VM):** Die VM fährt die
Hermes-Engine — dort gibt es kein Cockpit und damit keinen Self-Service
für den SSH-Key. Das ist kein Fehler deiner VM: der Admin hinterlegt den
Key (Vorlagen: `references/ssh-pubkey-handoff.md`), danach wie beim
„Nein"-Zweig unten weiter.

**„Cockpit-Adresse" → Self-Service (gateway-VM, engine=claude), kein Warten:**

1. Cockpit-URL im Browser öffnen, mit dem **Firmen-Konto** anmelden.
   (Funktioniert der Login, ist der User auf der VM bereits angelegt —
   genau dafür steht das Gateway-Mapping.)
2. Tab **System** → Karte **„SSH-Zugang"** → den Pubkey aus Schritt 4
   einfügen (Zwischenablage; die Zeile beginnt mit `ssh-ed25519`) →
   **„Key hinterlegen"**. Das Feld nimmt nur den öffentlichen Schlüssel —
   niemals die private Key-Datei öffnen oder hochladen.
3. Direkt weiter mit Schritt 6.

Fehlt die Karte „SSH-Zugang" im System-Tab, ist das Cockpit der VM noch zu
alt — dann den Admin-Weg unten nehmen und dem Admin nebenbei
`ki-os-fleet update` ans Herz legen.

**„Nein" → Admin-Weg (tunnel-VM oder unklar):**

Übergabe an den Admin anbieten — fertige Mail-/Slack-Vorlagen:
`references/ssh-pubkey-handoff.md`. Dann warten, bis der Admin den Key
hinterlegt und den User eingerichtet hat (Workspace, Cockpit-Service,
Display-Stack). `AskUserQuestion`:

> „Hat dein Admin bestätigt, dass dein User auf der VM angelegt ist?"
> Optionen: „Ja, kann's testen" | „Noch nicht — pausiere hier"

Bei „Noch nicht": pausieren — `/user-onboarding` später erneut aufrufen, der
Skill ist idempotent und macht bereits Erledigtes nicht kaputt.

### Schritt 6 — Smoketest + VM-Werte holen (ein SSH-Roundtrip)

```
bash "$SKILL_DIR/scripts/get-vm-values.sh"
# Windows: get-vm-values.ps1
```

Liefert `SSH_OK` + `ACCESS_MODE=` + `ENGINE=` + `AGENT_PORT=` + `COCKPIT_PORT=` / `NOVNC_PORT=` /
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
# engine=claude:
bash "$SKILL_DIR/scripts/setup-tunnels.sh" --novnc-port <NOVNC_PORT> --cockpit-port <COCKPIT_PORT>
# Windows: setup-tunnels.ps1 -NovncPort <NOVNC_PORT> -CockpitPort <COCKPIT_PORT>

# engine=hermes (zweiter Tunnel geht auf das Hermes-Dashboard, lokal 9119):
bash "$SKILL_DIR/scripts/setup-tunnels.sh" --engine hermes --novnc-port <NOVNC_PORT> --agent-port <AGENT_PORT>
# Windows: setup-tunnels.ps1 -Engine hermes -NovncPort <NOVNC_PORT> -AgentPort <AGENT_PORT>
```

Ein Aufruf richtet **beide** gehärteten Tunnel ein (idempotent, Windows
zusätzlich self-healing: räumt alt/falsch benannte Tunnel-/Daemon-Tasks
inhaltsbasiert weg). Unter Windows entsteht dabei EIN gemeinsamer Task
`ki-os-vm-watchdog`, der auch den Mutagen-Daemon aus Schritt 8 mit überwacht
(Reihenfolge 7 → 8 ist der Normalweg, aber keine Pflicht mehr: läuft Schritt 8
zuerst, legt er den Task selbst Mutagen-only an, und dieser Lauf erweitert ihn
um die Tunnel). Die Argumente sind die **VM-seitigen** Werte aus
Schritt 6 — nicht mit den festen lokalen Ports 6080/3847 verwechseln (falscher
Wert tunnelt auf das Display eines anderen Users!). Härtungs-Hintergrund +
Troubleshooting: `references/tunnels.md`.

### Schritt 8 — Mutagen-Sync einrichten

> **`HUB_BACKEND=cloud`? → Schritt komplett überspringen.** Die geteilten
> Ordner kommen dort über SharePoint/Google Drive der Firma; Mutagen wäre
> eine zweite Sync-Engine auf denselben Bytes (Konfliktkopien). Falls die VM
> gemischte Backends fährt und Mutagen doch gewünscht ist: vor dem Aufruf
> `COMPANY_LOCAL=<Firmenordner>` (aus get-vm-values) exportieren, damit das
> Skript den Firmenordner ignoriert.

```
bash "$SKILL_DIR/scripts/setup-mutagen.sh" --vm-user <VM_USER>
# Windows: setup-mutagen.ps1 -VmUser <VM_USER>
# --vm-user/-VmUser ist optional (das Skript erkennt den VM-User per SSH
# selbst) — im vollen Ablauf mitgeben, der Wert liegt aus Schritt 3 ohnehin
# vor. Ein früher nötiges -Gateway gibt es nicht mehr (wird ignoriert).
```

Installiert Mutagen (macOS: Homebrew; Linux: brew oder GitHub-Release;
Windows: GitHub-Release-Zip mit Download-Retry), richtet den Daemon-Autostart
ein (Windows: übernimmt der `ki-os-vm-watchdog`-Task aus Schritt 7; fehlt er,
legt `setup-mutagen.ps1` ihn selbst **additiv Mutagen-only** an —
`setup-tunnels.ps1 -EnsureMutagen`, räumt nichts ab, gilt für gateway- wie
tunnel-VMs) und legt die Session `ki-os` an.

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
Die **Endpunkte übernimmt die Neuanlage aus der laufenden Session** (nicht aus
der Konvention) — Bestands-Setups mit anderem SSH-Alias oder anderem lokalen
Ordner bleiben also intakt; sind die Endpunkte nicht lesbar, bricht das Skript
ab und terminiert nichts.

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

### Schritt 9 — Desktop-App vorkonfigurieren

**`ENGINE=hermes` → diesen Schritt überspringen.** Es gibt lokal nichts zu
registrieren: die **Hermes-Desktop-App** wird beim ersten Start als „Remote
gateway" verbunden — mit der URL und einem **Session-Token**. Beides liefert der
Admin (`ki-os-fleet vm hermes-token --user <VM_USER>`):

- `ACCESS_MODE=gateway` → die öffentliche `…-agent.…`-URL
- `ACCESS_MODE=tunnel` → `http://127.0.0.1:9119` durch den Tunnel aus Schritt 7

Dem User sagen: **Token wie ein Passwort behandeln** (er läuft nicht ab; bei
Verdacht rotiert der Admin ihn, dann muss die App neu verbunden werden).
Details, Anfrage-Vorlage an den Admin + Troubleshooting:
`references/hermes-desktop-app.md`.

Für `ENGINE=claude`:

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
    --engine <ENGINE> \
    [--gateway-cockpit-url <URL> --gateway-novnc-url <URL> --gateway-agent-url <URL>]
# Windows: verify.ps1 -VmUser <VM_USER> -Mode <ACCESS_MODE> -Engine <ENGINE> `
#     [-GatewayCockpitUrl <URL> -GatewayNovncUrl <URL> -GatewayAgentUrl <URL>]
```

Prüft SSH, die Zugangswege (tunnel: beide lokalen Tunnel; gateway: die zwei
HTTPS-URLs — 302 zum IdP-Login = OK), die Mutagen-Session, den lokalen
Sync-Ordner und die Desktop-App-Einträge (OK/WARN/FAIL pro Komponente).

Drei Dinge, die der Verify bewusst **zusätzlich** meldet, weil ein „laufender"
Sync sie verdeckt: anliegende **Konflikte** und **Transition problems** (Status
`Watching for changes` ist mit ihnen NICHT gesund) sowie **offene
Watchdog-Meldungen** (`SYNC-FAIL`/`SYNC-BLOCK`). Den lokalen Ordner liest der
Verify aus der Session, statt `~/KI-OS` anzunehmen — Bestands-Setups haben ihn
woanders. Zusätzlich den User **aktiv testen lassen**:

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
nächsten Schritte — **je nach `ENGINE` aus Schritt 6**:

**Für `ENGINE=hermes`:**

1. **Browser-Logins (einmalig):** im noVNC-Tab in die Zielsysteme einloggen —
   siehe „Browser-Logins & OAuth" unten. Einen Claude-/Modell-Login gibt es
   hier **nicht** — die Provider-Anmeldung hat der Admin bereits eingerichtet
   (`hermes auth add`), du musst nichts tun.
2. **Arbeiten** — über das **Agent-Dashboard** (tunnel:
   `http://localhost:9119`; gateway: `<GATEWAY_AGENT_URL>`) oder die
   **Hermes-Desktop-App** (URL + Session-Token vom Admin — Schritt 9 bzw.
   `references/hermes-desktop-app.md`).
3. **Geplante Aufgaben:** über den Scheduler im Dashboard bzw. `hermes cron`
   auf der VM — nicht `mitarbyte scheduler` (Claude-only, die CLI sagt es
   dir auch selbst).
4. **Dateien & Obsidian:** `~/KI-OS` ist der lokale Spiegel — als
   Obsidian-Vault öffnen, im Finder/Explorer nutzen; Änderungen syncen
   automatisch.

**Für `ENGINE=claude`:**

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
