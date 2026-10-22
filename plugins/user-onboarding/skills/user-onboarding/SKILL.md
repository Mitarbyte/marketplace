---
name: user-onboarding
description: "Lokales Onboarding fuer einen Mitarbeiter, der einen vom Admin bereits auf einer Firmen-VM angelegten KI-OS-Workspace nutzen will. Use when someone says 'KI-OS einrichten', 'vm-zugriff einrichten', 'hermes-app verbinden', 'agent-adresse bekommen', 'cockpit-adresse bekommen', 'ssh-key fuer firmen-vm', 'mit der firmen-vm verbinden', 'desktop-app mit der firmen-vm verbinden', 'lokales setup fuer hub-vm', '/user-onboarding'. Also trigger when someone just got their Cockpit or Agent address (company login URL) from an admin and wants to start using their workspace, or when an existing user wants to refresh/repair their local setup (re-run is the update). Zugang ist immer das Gateway mit Firmen-Login, ohne VNC-Passwort und ohne lokalen Datei-Spiegel. Die Weiche sind die Engine-Pakete der VM, erkannt an der Adresse vom Admin: Cockpit-Adresse (Claude-Paket) = SSH-Key, den der User im Cockpit selbst hinterlegt, plus Vorkonfiguration der Claude-Desktop-App (SSH-Host ki-os-vm); Agent-Adresse (Hermes-Paket) = Hermes-Desktop-App mit URL + Firmen-Login, Anmeldungen im Screen der App (Uebernehmen); nur eine Agent-Adresse = Pfad H ohne SSH. Fertige Skripte in scripts/, SSH-Alias fest ki-os-vm. Plattformen: macOS, Linux, Windows (PowerShell + Windows-OpenSSH; WSL2 als Alternative)."
---

## Was dieser Skill macht

Richtet auf dem lokalen Gerät (macOS/Linux/Windows) den Zugang zur bereits
vom Admin eingerichteten Firmen-VM ein. **Zugang ist immer das Gateway:**
Cockpit, Agent-Adresse, Artefakte und — nur im Claude-Paket — VM-Desktop
laufen über HTTPS-URLs mit dem Firmen-Login; lokal wird nur eingerichtet, was
das Gateway nicht ersetzt. **Die Engine-Pakete der VM entscheiden über den
Ablauf; der User erkennt sie an den Adressen vom Admin** (Schritt 3):

| | **Claude-Paket** — Cockpit-Adresse | **Hermes-Paket** — Agent-Adresse |
|---|---|---|
| Woran erkennbar | **Cockpit-URL** (`https://<name>-cockpit.…`) + Firmen-Login | **Agent-URL** (`https://<name>-agent.…`) + Firmen-Login |
| SSH-Key | User trägt ihn **selbst im Cockpit** ein (System-Tab) | — |
| Desktop-App | Claude-Desktop-App (SSH-Host `ki-os-vm`) | **Hermes-Desktop-App, Pflicht** (Remote gateway: URL + Firmen-Login) |
| Anmeldungen bei Websites | VM-Chrome im **VM-Desktop** (Gateway-URL) | **Desktop-App → Screen → Übernehmen** |
| Dateien | Cockpit-Explorer bzw. Cloud-Client der Firma | Desktop-App bzw. Cloud-Client der Firma |

Hat die VM **beide Pakete**, kamen beide Adressen: dann gelten beide Spalten.
Kam **nur eine Agent-Adresse**, ist das **Pfad H**: kein SSH-Key, kein Skript,
kein VM-Zugriff vom Gerät (ADR 22 Nr. 10) — nur Schritt 8 (App) und 10.

**Die gesamte Mechanik liegt in fertigen, parametrisierten Skripten unter
`scripts/`** — der Skill orchestriert nur: Inputs einsammeln, Skripte mit
Argumenten aufrufen, Output-Marker auswerten, User führen. Die Skripte NICHT
im Chat nachbauen oder abwandeln; das Warum steht in `references/`.

**Nicht-Ziele:** VM-seitiges Setup (Admin-Sache), lokale Hub-Klone, lokale
Datei-Spiegel, Browser-Logins (macht der User selbst auf der VM).

**`PACKAGES`** (`hermes`, `claude` oder `hermes,claude`): mit SSH-Zugang liest
Schritt 7 sie von der VM, sonst folgen sie aus den Adressen (Schritt 3);
abgefragt werden sie nie. Jeder Schritt fragt nur: Claude-Paket dabei?
Hermes-Paket dabei?

## Konventionen

- **SSH-Alias fest `ki-os-vm`** — wird nie abgefragt. Desktop-App-Einträge
  leiten sich daraus ab.
- **Minimale `~/.ssh/config`:** nur der `Host ki-os-vm`-Block, keine
  Forward-Zeilen, kein ControlMaster (`references/ssh.md`).
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
(Default; PowerShell + Windows-OpenSSH) oder **WSL2** (User startet `wsl` und
durchläuft den Linux-Pfad).

### Schritt 2 — Vorbedingungen (nur natives Windows)

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>\scripts\check-prereqs.ps1"
```

Prüft/installiert Windows-OpenSSH-Client (Install braucht Admin — bei
`MISSING_ADMIN` den User eine Admin-PowerShell öffnen lassen) und Git for
Windows (Pflicht für Claude Code auf nativem Windows). macOS/Linux: überspringen.

### Schritt 3 — Weg bestimmen (die Weiche)

`AskUserQuestion` — eine Frage, die den Weg festlegt:

> „Was hast du vom Admin bekommen?"
> - **„Eine Cockpit-Adresse"** (`https://<name>-cockpit.…`, Login mit dem
>   Firmen-Konto) → **Claude-Paket**: SSH-Key per Self-Service, dann
>   Desktop-App. Kam zusätzlich eine Agent-Adresse, hat die VM beide Pakete —
>   derselbe Weg, Schritt 8 verbindet dann auch die Hermes-App.
> - **„Nur eine Agent-Adresse, keine Cockpit-Adresse"**
>   (`https://<name>-agent.…`) → **nur Hermes-Paket = Pfad H**:
>   kein SSH-Key, kein Skript, kein VM-Zugriff vom Gerät — direkt weiter mit
>   **Schritt 8** (Hermes-App), danach Schritt 10.
> - **„Weiß ich nicht / nichts davon"** → hier pausieren; der Admin schickt die
>   Adressen (`ki-os-fleet vm zugang --user <n>` gibt alle aus).

Ergebnis merken als `PFAD_H` (ja|nein). **`PFAD_H=ja` → Schritte 4–7 und 9
entfallen** (es gibt nichts Lokales einzurichten oder zu prüfen).

Kam vom Admin nur **IP + Username**, liegt eine eingefrorene v2-VM vor: dann
hier abbrechen, die alte Fassung dieses Skills aus dem Kanal
`https://raw.githubusercontent.com/Mitarbyte/marketplace/v2-lts/install.sh`
(Windows: `…/v2-lts/install.ps1`) installieren und `/user-onboarding` neu starten.

### Schritt 4 — User-Inputs sammeln

`AskUserQuestion`: **VM-Adresse** und **VM-Username** — beide stecken in der
Cockpit-Adresse `https://<VM_USER>-cockpit.<VM-Adresse>` (z. B.
`srv123456.hstgr.cloud`; eine IP vom Admin geht genauso) —, dazu **Email** für
den Key-Kommentar (Default: `git config --global user.email`). Keine weiteren
Fragen.

### Schritt 5 — SSH-Key + Config

```
bash "$SKILL_DIR/scripts/setup-ssh.sh" --ip <VM_ADRESSE> --user <VM_USER> --email <EMAIL>
# Windows: setup-ssh.ps1 -VmIp <VM_ADRESSE> -VmUser <USER> -Email <EMAIL>
```

Erzeugt den Ed25519-Key nur, falls keiner existiert (`KEY_EXISTS` →
bestehender Key wird genutzt; will der User explizit einen neuen, erst den
alten wegsichern, dann `--new-key`/`-NewKey`). Schreibt den `Host ki-os-vm`-Block
idempotent und legt den Public Key in die Zwischenablage (`PUBKEY:`-Zeile).

### Schritt 6 — Public Key im Cockpit hinterlegen

Den Key dem User zeigen (er liegt auch in der Zwischenablage). Self-Service,
kein Warten:

1. Cockpit-URL im Browser öffnen, mit dem **Firmen-Konto** anmelden.
   (Funktioniert der Login, ist der User auf der VM bereits angelegt.)
2. Tab **System** → Karte **„SSH-Zugang"** → Pubkey einfügen (die Zeile beginnt
   mit `ssh-ed25519`) → **„Key hinterlegen"**. Das Feld nimmt nur den
   öffentlichen Schlüssel — niemals die private Key-Datei hochladen.
3. Direkt weiter mit Schritt 7.

**Rückfall**, falls die Karte fehlt oder der Self-Service scheitert: den
Pubkey (nicht geheim) an den Admin schicken, der ihn mit
`ki-os-fleet vm adduser <VM_USER> --pubkey <key>` hinterlegt, und
`/user-onboarding` nach seiner Bestätigung erneut starten (idempotent).

### Schritt 7 — Smoketest + VM-Werte (ein SSH-Roundtrip)

```
bash "$SKILL_DIR/scripts/get-vm-values.sh"
# Windows: get-vm-values.ps1
```

Liefert `SSH_OK` + `PACKAGES=` und die Gateway-URLs der Pakete: mit
Claude-Paket `GATEWAY_COCKPIT_URL=`, `DISPLAY_STACK=` und `GATEWAY_NOVNC_URL=`,
mit Hermes-Paket `GATEWAY_AGENT_URL=`, immer `GATEWAY_APPS_URL=`. Werte merken.

- Es gibt **kein** VNC-Passwort (x11vnc läuft mit `-nopw`, ADR § 5.6) — nicht
  danach fragen, keins übermitteln.
- `SSH_FAIL` → `references/ssh.md` → Smoketest.
- `DISPLAY_STACK=MISSING` → VM-Desktop nicht provisioniert → Admin.
  `DISPLAY_STACK=AUS` ist gewollt (Option des Claude-Pakets): kein VM-Desktop,
  Website-Logins laufen dann im Screen der Hermes-App.
- `GATEWAY_*_URL=MISSING` bzw. `WARN: kein Gateway-Mapping` → Admin
  (`ki-os-fleet vm gateway-grant`).

### Schritt 8 — Desktop-Apps einrichten

**Hermes-Paket** (in `PACKAGES` oder `PFAD_H=ja`): lokal ist nichts zu
registrieren. Die **Hermes-Desktop-App** ist **Pflicht** (installiert in
Anleitung Teil 2) und wird unter **Settings → Gateways → Remote gateway** mit
der **Agent-URL** verbunden; angemeldet wird per **Firmen-Login**, den die App
im System-Browser öffnet — einen Session-Token gibt es nicht. Die URL kommt
aus Schritt 7 (`GATEWAY_AGENT_URL`) bzw. vom Admin
(`ki-os-fleet vm zugang --user <VM_USER>`). Danach einmal den **Screen**
öffnen (Bots → Bot → Screen bzw. die Screen-Box in der Sessions-Leiste): dort
laufen später alle Anmeldungen (**Übernehmen** → anmelden → **Zurückgeben**).
**Pfad H:** das ist der einzige Einrichtungsschritt, weiter mit Schritt 10.
Details + Tastatur-Hinweis: `references/hermes-desktop-app.md`.

**Claude-Paket** (in `PACKAGES`):

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

### Schritt 9 — Verifikation

**`PFAD_H=ja` → entfällt** (kein SSH, nichts Lokales): die Prüfung ist, dass
die Agent-URL nach dem Firmen-Login lädt und die App verbindet; ein **200 ohne
Login** gehört sofort an den Admin.

```
bash "$SKILL_DIR/scripts/verify.sh" --vm-user <VM_USER> --packages <PACKAGES> \
    [--gateway-cockpit-url <URL> --gateway-novnc-url <URL> --gateway-agent-url <URL> --gateway-apps-url <URL>]
# Windows: verify.ps1 -VmUser <VM_USER> -Packages <PACKAGES> `
#     [-GatewayCockpitUrl <URL> -GatewayNovncUrl <URL> -GatewayAgentUrl <URL> -GatewayAppsUrl <URL>]
```

Nur die URLs übergeben, die Schritt 7 geliefert hat (ohne `GATEWAY_NOVNC_URL`
kein VM-Desktop-Check). Prüft SSH, die HTTPS-URLs je Paket (302/401/403 zum
IdP-Login = OK, ein **200 unauthentifiziert** ist ein Auth-Bypass und gehört
sofort an den Admin) und mit Claude-Paket die Desktop-App-Einträge.

Zusätzlich den User **aktiv testen lassen**:

1. Claude-Paket mit VM-Desktop: `<GATEWAY_NOVNC_URL>` öffnen → „Mit
   Microsoft/Google anmelden" → VM-Desktop erscheint (**kein** Passwort;
   leer/grau ist okay, solange kein Chrome läuft). Claude-Desktop-App (nach
   Neustart): `ki-os-vm` / `KI-OS` wählen — es darf kein Trust-Prompt erscheinen.
2. Hermes-Paket: Hermes-App verbindet, der Screen zeigt ein Live-Bild.

Bei FAILs: SSH → `references/ssh.md`; eine fehlende oder falsch antwortende
Gateway-URL gehört an den Admin.

### Schritt 10 — Abschluss

Statustabelle aus dem `verify`-Output zeigen (Pfad H: App verbunden, Screen
sichtbar), dann die nächsten Schritte je Paket:

**Claude-Paket:**

1. **Claude-Login — ZUERST (einmalig):** im VM-Browser (`<GATEWAY_NOVNC_URL>`)
   in **claude.ai** einloggen. Der einzige Claude-Auth-Schritt, den der User
   selbst macht — Voraussetzung für Desktop-App, Scheduler und Remote-Control.
   Die VM baut daraus automatisch beides: den Full-Scope-OAuth-Login für
   `claude remote-control` (`ki-os-relogin`-Watcher heilt bei Ablauf selbst) und
   den long-lived Inference-Token (`ki-os-setup-token`, entsteht binnen Minuten).
   Läuft die Session ab, öffnet der Watcher im VM-Desktop ein kleines
   Login-Terminal — Link folgen, Code eingeben. Ohne VM-Desktop
   (`DISPLAY_STACK=AUS`) den Admin fragen. Details: `references/api-keys.md`.
2. **Arbeiten** — primär **Claude-Desktop-App** (Remote-Projekt `ki-os-vm` /
   `KI-OS`). Fallbacks: `claude.ai/code` · `ssh ki-os-vm` → `cd ~/KI-OS && claude` ·
   VS Code Remote-SSH (`references/vscode-remote-ssh.md`). Cockpit und
   VM-Desktop laufen über die Gateway-URLs, von jedem Gerät ohne lokales Setup.
3. **Geplante Aufgaben:** `mitarbyte scheduler` bzw. Cockpit.
4. **Dateien:** Cockpit-Explorer bzw. der Cloud-Client der Firma — einen
   lokalen Spiegel gibt es nicht.

**Hermes-Paket:**

1. **Anmeldungen (einmalig):** dem Agenten sagen „Melde mich bei Outlook an"
   (oder im Dashboard-Tab **KI-OS → Anmeldungen** unter der Agent-URL im
   Browser „Anmelden" klicken). Der Login öffnet sich im Screen: **Desktop-App
   → Screen → Übernehmen**, anmelden, **Zurückgeben**. Passwörter tippt der
   Mensch, nie der Agent; der Screen läuft mit US-Tastatur
   (`references/hermes-desktop-app.md`). Einen Claude-/Modell-Login gibt es
   hier **nicht** — die Provider-Anmeldung hat der Admin eingerichtet.
2. **Arbeiten** — in der **Hermes-Desktop-App** (Pflicht, Schritt 8); das
   Dashboard im Browser (Agent-URL) bleibt Fallback. **Artefakte**
   (Dashboards, kleine Web-Apps) stehen im Dashboard-Tab „KI-OS → Artefakte"
   unter festen URLs (`<Apps-URL>/<slug>/` hinter dem Firmen-Login).
3. **Geplante Aufgaben:** in der App (Bots → Bot → Scheduled Jobs) bzw.
   `hermes cron` — dort sieht der User auch Fehlläufe; ein Zustellkanal
   (Mail/WhatsApp) ist eine Option, die der Admin bei der Übergabe setzt.
4. **Dateien:** über die Desktop-App bzw. den Cloud-Client der Firma
   (SharePoint/Drive); einen lokalen Spiegel gibt es nicht.

**Beide Pakete:** die Hermes-Desktop-App ist der primäre Einstieg, Cockpit +
Claude-Desktop-App kommen dazu; der Claude-Login ist einmalig nötig. Jedes
Paket hat sein eigenes Chrome-Profil — Website-Logins also einmal im Screen
(Hermes) und einmal im VM-Desktop (Claude). Geplante Aufgaben: `hermes cron`
**und** `mitarbyte scheduler` laufen parallel — Jobs des anderen Agenten nicht
anfassen.

---

## Re-Run = Update (Bestands-User)

Ein erneuter Lauf IST das Update: alle Schritte laufen idempotent (bestehender
Key bleibt, `ki-os-vm`-Block und Desktop-App-Einträge werden neu geschrieben).
Auf **Pfad H** gibt es nichts zu re-deployen — verbindet die App nicht mehr,
meldet sich der User in der App neu per Firmen-Login an.

---

## Browser-Logins & OAuth (Doku für den User)

Alles läuft auf der VM, nie im lokalen Browser des Geräts:

- **Website-Logins (Google, GitHub-Web, CRM, …):** einmalig einloggen — mit
  Hermes-Paket im **Screen der Desktop-App** (Übernehmen), mit Claude-Paket im
  VM-Chrome (VM-Desktop über die Gateway-URL). Die Sessions bleiben auf der VM
  und stehen dem Agenten zur Verfügung. **Keine privaten/Banking-Logins** in
  diesen Profilen — der Agent kann auf alles zugreifen.
- **OAuth-Flows von CLIs auf der VM** (`gh auth login`, `gws auth login`,
  MCP-OAuth): mit Hermes-Paket den Agenten bitten — der Browser öffnet sich im
  Screen; mit Claude-Paket per SSH mit dem `ki-os-auth`-Wrapper starten
  (`ki-os-auth gh auth login`) — der Browser öffnet sich im VM-Desktop.
  Loopback-Callbacks funktionieren, weil CLI und Browser auf derselben VM laufen.
- **Device-/Paste-Code-Flows** (`claude auth login`, `gh` Device-Flow): Code +
  URL erscheinen im Chat/Terminal — URL im **lokalen** Browser öffnen, Code
  eingeben.

## Hinweise

- **Idempotent:** Alle Skripte prüfen den Zustand; der `ki-os-vm`-Config-Block
  wird bewusst überschrieben, damit Konfig-Drift nicht unbemerkt bleibt. Der
  SSH-Key wird nie ungefragt ersetzt.
- **Sicherheit:** Private Keys nie ausgeben oder loggen. API-Tokens fasst
  dieser Skill nicht an.
- **Windows nativ:** Alle SSH-Schritte nutzen den nativen Windows-OpenSSH
  (`C:\Windows\System32\OpenSSH\ssh.exe`); die Git-Bash-ssh nicht davor in den
  PATH stellen.
