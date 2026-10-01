---
name: user-onboarding
description: "Lokales Onboarding fuer einen Mitarbeiter, der einen vom Admin bereits auf einer Firmen-VM angelegten KI-OS-Workspace nutzen will. Use when someone says 'KI-OS einrichten', 'vm-zugriff einrichten', 'hermes-app verbinden', 'agent-adresse bekommen', 'cockpit-adresse bekommen', 'ssh-key fuer firmen-vm', 'mit der firmen-vm verbinden', 'desktop-app mit der firmen-vm verbinden', 'lokales setup fuer hub-vm', '/user-onboarding'. Also trigger when someone just got their Cockpit or Dashboard address (company login URL) from an admin and wants to start using their workspace, or when an existing user wants to refresh/repair their local setup (re-run is the update). Zugang ist immer das Gateway: Cockpit, Dashboard, Artefakte und VM-Desktop laufen ueber HTTPS-URLs mit Firmen-Login, es gibt kein VNC-Passwort und keinen lokalen Datei-Spiegel. Die Weiche haengt nur an der Engine und wird als ERSTES ueber die Adresse vom Admin bestimmt: Cockpit-Adresse (Claude-Stack, engine=claude|hybrid) = SSH-Key, den der User im Cockpit SELBST hinterlegt, plus Vorkonfiguration der Claude-Desktop-App auf macOS/Windows (SSH-Host ki-os-vm in ssh_configs.json + ~/.claude.json-Workspace-Eintrag); Dashboard-Adresse ohne Cockpit (reine Hermes-VM) = Pfad H OHNE SSH und ohne VM-Zugriff: Hermes-Desktop-App mit Dashboard-URL + VM-Desktop-Link vom Admin (ki-os-fleet vm zugang), Anmeldung ueber den Firmen-Login im System-Browser, Firmen-Tools im Dashboard-Tab KI-OS → Anmeldungen. Alles laeuft ueber fertige, parametrisierte Skripte in scripts/. Der SSH-Alias ist fest ki-os-vm. Der Workspace auf der VM ist bereits vom Admin angelegt und wird hier nicht angefasst; Browser + Logins laufen im VM-Chrome (VM-Desktop ueber die Gateway-URL). Plattformen: macOS, Linux, Windows (nativ ueber PowerShell + Windows-OpenSSH; WSL2 als Alternative)."
---

## Was dieser Skill macht

Richtet auf dem lokalen Gerät (macOS/Linux/Windows) den Zugang zur bereits
vom Admin eingerichteten Firmen-VM ein. **Zugang ist immer das Gateway:**
Cockpit, Hermes-Dashboard, Artefakte und VM-Desktop (noVNC) laufen über
HTTPS-URLs mit dem Firmen-Login — lokal wird nur eingerichtet, was das Gateway
nicht ersetzt. **Die Engine der VM entscheidet über den Ablauf; der User
erkennt sie an der Adresse vom Admin** (Schritt 3):

| | **Cockpit-Adresse** (`engine=claude\|hybrid`) | **reine Hermes-VM — Pfad H** (`engine=hermes`) |
|---|---|---|
| Woran erkennbar | Admin schickte eine **Cockpit-URL** (`https://<name>-cockpit.…`) + Firmen-Login | Admin schickte **Dashboard-URL** (`https://<name>-agent.…`) + **VM-Desktop-Link**, keine Cockpit-URL |
| SSH-Key | User trägt ihn **selbst im Cockpit** ein (System-Tab) | **entfällt** — kein SSH, kein VM-Zugriff vom Gerät (ADR 22 Nr. 10) |
| Desktop-App | Claude-Desktop-App (`claude\|hybrid`), dazu die Hermes-App (`hybrid`) | **Hermes-Desktop-App** (Remote gateway: URL + Firmen-Login) |
| Dateien | Cockpit-Explorer bzw. Cloud-Client der Firma | Dashboard/VM-Desktop bzw. Cloud-Client der Firma |
| Skripte aus `scripts/` | ja | **keine** — nur Schritt 8 (App) + 10 (Abschluss) |

**Die gesamte Mechanik liegt in fertigen, parametrisierten Skripten unter
`scripts/`** — der Skill orchestriert nur: Inputs einsammeln, Skripte mit
Argumenten aufrufen, Output-Marker auswerten, User führen. Die Skripte NICHT
im Chat nachbauen oder abwandeln; das Warum steht in `references/`.

**Nicht-Ziele:** VM-seitiges Setup (Admin-Sache), lokale Hub-Klone, lokale
Datei-Spiegel, Browser-Logins (macht der User selbst im VM-Chrome).

**`ENGINE`** (`claude` | `hybrid` | `hermes`): der User erkennt sie an der
Adresse (Schritt 3), mit SSH-Zugang liest Schritt 7 sie von der VM; abgefragt
wird sie nie. Entscheidend ist der **Stack**, nicht der Wert: Claude-Stack =
`claude|hybrid`, Hermes-Stack = `hermes|hybrid`.

- **claude:** Cockpit als Oberfläche, Claude-Code-Desktop-App als Arbeitszugang.
- **hermes:** **kein Cockpit** — Oberfläche ist das Hermes-Dashboard, der
  Arbeitszugang die Hermes-Desktop-App; Artefakte liegen hinter der Apps-URL;
  Schritt 8 (Claude-Desktop-App) entfällt.
- **hybrid:** **beide** — Hermes-Dashboard (primär) **und** Cockpit, also zwei
  Agenten-URLs (`…-agent.…` + `…-cockpit.…`); Schritt 8 läuft wie auf claude,
  die Hermes-App kommt dazu.

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
>   Firmen-Konto) → **Claude-Stack** (`claude|hybrid`): SSH-Key per
>   Self-Service, dann Desktop-App. (Kam zusätzlich eine Dashboard-Adresse,
>   ist die VM `hybrid` — derselbe Weg.)
> - **„Eine Dashboard-Adresse + VM-Desktop-Link, keine Cockpit-Adresse"**
>   (`https://<name>-agent.…`) → **reine Hermes-VM = Pfad H**:
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

Liefert `SSH_OK` + `ENGINE=` + `DISPLAY_STACK=` + `GATEWAY_COCKPIT_URL=` /
`GATEWAY_NOVNC_URL=` (+ `GATEWAY_AGENT_URL=` + `GATEWAY_APPS_URL=` auf hermes
**und** hybrid). Werte merken.

- Es gibt **kein** VNC-Passwort (x11vnc läuft mit `-nopw`, ADR § 5.6) — nicht
  danach fragen, keins übermitteln.
- `SSH_FAIL` → `references/ssh.md` → Smoketest.
- `DISPLAY_STACK=MISSING` → Display-Stack nicht provisioniert → Admin.
- `GATEWAY_*_URL=MISSING` → kein Gateway-Mapping für diesen User → Admin
  (`ki-os-fleet vm gateway-grant`).

### Schritt 8 — Desktop-App vorkonfigurieren

**`ENGINE=hermes` → Registrierung überspringen** (`hybrid` läuft wie `claude`). Es gibt lokal nichts zu registrieren: die
**Hermes-Desktop-App** ist auf `hermes|hybrid` **Pflicht** (installiert in
Anleitung Teil 2) und wird als „Remote gateway" mit der **URL** verbunden;
angemeldet wird per **Firmen-Login**, den die App im System-Browser öffnet
(RFC 8252 + PKCE) — **einen Session-Token gibt es seit dem 20.09.2026 nicht
mehr**, nichts ist aufzubewahren oder geschützt zu übertragen. Die Werte kommen
vom Admin aus **einer** Ausgabe (`ki-os-fleet vm zugang --user <VM_USER>`):
**Dashboard-URL** (`https://<VM_USER>-agent.…`) und **VM-Desktop-URL**
(noVNC). **Pfad H:** das ist der einzige Einrichtungsschritt; danach
Dashboard-URL und VM-Desktop im Browser öffnen (Firmen-Login → Dashboard bzw.
Desktop), App verbinden, weiter mit Schritt 10. Details + Vorlage:
`references/hermes-desktop-app.md`.

Für `ENGINE=claude` und `ENGINE=hybrid`:

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
Dashboard-URL und VM-Desktop-URL nach dem Firmen-Login laden und die App
verbindet; ein **200 ohne Login** auf einer der URLs gehört sofort an den Admin.

```
bash "$SKILL_DIR/scripts/verify.sh" --vm-user <VM_USER> --engine <ENGINE> \
    [--gateway-cockpit-url <URL> --gateway-novnc-url <URL> --gateway-agent-url <URL> --gateway-apps-url <URL>]
# Windows: verify.ps1 -VmUser <VM_USER> -Engine <ENGINE> `
#     [-GatewayCockpitUrl <URL> -GatewayNovncUrl <URL> -GatewayAgentUrl <URL> -GatewayAppsUrl <URL>]
```

Prüft SSH, die HTTPS-URLs je Stack + VM-Desktop (Werte aus Schritt 7 —
302/401/403 zum IdP-Login = OK, ein **200 unauthentifiziert** ist ein
Auth-Bypass und gehört sofort an den Admin) und die Desktop-App-Einträge.

Zusätzlich den User **aktiv testen lassen**:

1. `<GATEWAY_NOVNC_URL>` öffnen → „Mit Microsoft/Google anmelden" →
   VM-Desktop erscheint (**kein** Passwort; leer/grau ist okay, solange kein
   Chrome läuft).
2. Desktop-App (nach Neustart): `ki-os-vm` / `KI-OS` wählen — es darf kein
   Trust-Prompt erscheinen.

Bei FAILs: SSH → `references/ssh.md`; eine fehlende oder falsch antwortende
Gateway-URL gehört an den Admin.

### Schritt 10 — Abschluss

Statustabelle aus dem `verify`-Output zeigen, dann die nächsten Schritte:

**`ENGINE=claude`:**

1. **Claude-Login — ZUERST (einmalig):** im VM-Browser (`<GATEWAY_NOVNC_URL>`)
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
   VS Code Remote-SSH (`references/vscode-remote-ssh.md`). Cockpit und
   VM-Desktop laufen über die Gateway-URLs, von jedem Gerät ohne lokales Setup.
3. **Browser-Logins (einmalig):** siehe unten.
4. **Dateien:** Cockpit-Explorer bzw. der Cloud-Client der Firma — einen
   lokalen Spiegel gibt es nicht.

**`ENGINE=hybrid`:** beides — Hermes-Desktop-App ist der primäre Einstieg (wie
`hermes`, Punkt 2), daneben Cockpit + Claude-Desktop-App (wie `claude`); der
Claude-Login ist einmalig nötig. Geplante Aufgaben: `hermes cron` (Dashboard)
**und** `mitarbyte scheduler` (Cockpit) laufen parallel — Jobs der anderen
Engine nicht anfassen.

**`ENGINE=hermes`:**

1. **Anmeldungen (einmalig):** Firmen-Tools im **Dashboard-Tab „KI-OS →
   Anmeldungen"** — je Datenquelle Zustand und Knopf **„Anmelden"**, der Login
   läuft im Browser des **VM-Desktops** (Link aus der Übergabe; Passwörter
   tippt der Mensch, nie der Agent). Alternativ dem Agenten sagen „Melde mich
   bei Outlook an". Browser-Logins (Web-Tools) direkt im VM-Desktop, siehe
   unten. Einen Claude-/Modell-Login gibt es hier **nicht** — die
   Provider-Anmeldung hat der Admin eingerichtet.
2. **Arbeiten** — in der **Hermes-Desktop-App** (Pflicht, Schritt 8); das
   **Dashboard** im Browser (`<Dashboard-URL>`) bleibt Fallback;
   **Artefakte** (Dashboards, kleine Web-Apps) stehen im Tab „KI-OS →
   Artefakte" unter festen URLs (`<Apps-URL>/<slug>/` hinter dem Firmen-Login).
3. **Geplante Aufgaben:** Scheduler im Dashboard bzw. `hermes cron` auf der VM
   — nicht `mitarbyte scheduler` (Claude-only).
4. **Dateien:** über Dashboard und VM-Desktop bzw. den Cloud-Client der Firma
   (SharePoint/Drive); einen lokalen Spiegel gibt es nicht.

---

## Re-Run = Update (Bestands-User)

Ein erneuter Lauf IST das Update: alle Schritte laufen idempotent (bestehender
Key bleibt, `ki-os-vm`-Block und Desktop-App-Einträge werden neu geschrieben).
Auf **Pfad H** gibt es nichts zu re-deployen — verbindet die App nicht mehr,
meldet sich der User in der App neu per Firmen-Login an.

---

## Browser-Logins & OAuth (Doku für den User)

Alles läuft auf der VM:

- **Browser-Logins (Google, GitHub-Web, CRM, …):** Im VM-Chrome (VM-Desktop
  über die Gateway-noVNC-URL) einmalig einloggen — die Sessions persistieren auf
  der VM und stehen dem Agent zur Verfügung. **Keine privaten/Banking-Logins** in
  diesem Profil — der Agent kann auf alles zugreifen.
- **OAuth-Flows von CLIs auf der VM** (`gh auth login`, `gws auth login`,
  MCP-OAuth): auf der VM mit dem `ki-os-auth`-Wrapper starten (z.B.
  `ki-os-auth gh auth login`) — der Browser öffnet sich im VM-Desktop,
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
