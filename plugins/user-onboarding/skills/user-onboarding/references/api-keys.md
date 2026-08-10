# API-Keys (auf der VM eintragen)

Nach abgeschlossenem Onboarding loggst du dich per `ssh ki-os-vm` ein
(Default `ki-os-vm`) und befuellst — falls dein Hub das vorsieht — die
`.env`-Datei in deinem Workspace mit den noetigen API-Keys.

> **Engine-Hinweis:** Die Abschnitte „API-Keys" und „OAuth statt API-Key"
> gelten fuer beide Engines (claude UND hermes). Ab „Claude-Code-Auth"
> ist alles **nur engine=claude**.

Pfad: `~/KI-OS/.env` (Workspace-Root auf der VM). Viele Hubs verwalten
ihre MCP-Secrets zentral ueber den Admin — frag im Zweifel deinen Admin,
ob und welche Keys du selbst eintragen musst.

Die hier gelisteten Variablen sind **Beispiele** der ueblichen Verdaechtigen
in KI-OS-Hubs — die tatsaechlich noetigen Keys haengen von deinem konkreten
Hub ab:

| Variable | Wo holen | Wofuer |
|----------|----------|--------|
| `CLICKUP_API_KEY` | ClickUp → Settings → Apps → API Token | Projektmanagement |
| `CLICKUP_TEAM_ID` | URL beim Anmelden: `app.clickup.com/<TEAM_ID>/...` | ClickUp |
| `FIREFLIES_API_KEY` | app.fireflies.ai/integrations/custom/fireflies → API Key | Meeting-Transkripte |
| `GHL_API_KEY` | GoHighLevel → Settings → API Keys | CRM |
| `GHL_LOCATION_ID` | GoHighLevel → Settings → Business Profile → Location ID | CRM |
| `YOUTUBE_API_KEY` | console.cloud.google.com → APIs & Services → Credentials | YouTube-Recherche |
| `GOOGLE_API_KEY` | console.cloud.google.com → APIs & Services → Credentials | NotebookLM, andere Google AI APIs |
| `PIPEDRIVE_API_TOKEN` | Pipedrive → Personal Preferences → API | CRM (falls Pipedrive statt GHL) |
| `PIPEDRIVE_DOMAIN` | dein Pipedrive-Subdomain (z.B. `acme.pipedrive.com`) | Pipedrive |
| `KLICKTIPP_USERNAME` / `KLICKTIPP_PASSWORD` | KlickTipp-Account-Credentials | E-Mail-Marketing |

## OAuth statt API-Key

Manche CLIs/MCPs nutzen OAuth — keine `.env`-Eintraege noetig, dafuer
einmaliger Browser-Login. Das laeuft komplett **auf der VM**: der
`ki-os-auth`-Wrapper startet das CLI mit dem richtigen Display, der
Browser oeffnet sich im noVNC-Tab (`http://localhost:6080/vnc.html?resize=scale`):

```bash
ssh ki-os-vm
# auf der VM:
ki-os-auth gws auth login        # Google Workspace (Drive, Gmail, Calendar, Docs, ...)
ki-os-auth gh auth login         # GitHub CLI
```

Waehrenddessen den noVNC-Tab offen halten und den Login dort
durchklicken.

## Claude-Code-Auth

> **Gilt nur auf `engine=claude`.** Auf hermes gibt es keinen Claude-Login,
> keine Token-Datei und kein `ki-os-setup-token` — die Modell-Anmeldung
> (`hermes auth add <provider>`) macht der Admin einmalig; du musst hier
> nichts tun.

`claude` selbst loggt sich mit deinem persoenlichen Claude Max/Pro Account
ein. **Long-lived Tokens** (`CLAUDE_CODE_OAUTH_TOKEN`) reichen NICHT fuer
`claude remote-control` — der Service lehnt sie als "inference-only" ab.

Seit Claude Code 2.x laeuft der Login ueber einen **Paste-Code-Flow** mit
gehosteter Callback-URL — kein Wrapper noetig:

```bash
ssh ki-os-vm
# auf der VM:
claude auth login
# URL aus dem Terminal in deinen LOKALEN Browser kopieren,
# bei Anthropic einloggen, angezeigten Code zurueck ins Terminal pasten.
```

### Langzeit-Zugang (Long-lived Token) — EIN Handgriff im noVNC

Damit deine **normalen** `claude`-Sessions (interaktiv im noVNC-Terminal,
Scheduler/headless) ohne monatlichen Re-Login laufen, brauchst du einen
Long-lived, inference-only Token. Er gilt **~1 Jahr**.

**Warum das wichtig ist:** ohne ihn haengen deine geplanten Aufgaben am
normalen OAuth-Login — und der laeuft **30 Tage nach deiner letzten
interaktiven Anmeldung** ab (er verlaengert sich NICHT dadurch, dass die VM
laeuft oder Jobs erfolgreich sind). Ist er weg, stehen die Jobs, bis du dich
neu anmeldest.

**Was du tust — einmal:**

1. noVNC oeffnen (Cockpit → System, oder der Button „Langzeit-Zugang fehlt")
2. Auf dem Desktop erscheinen ein Hinweisfenster und die Claude-Anmeldung
3. Anmelden (falls gefragt) und das **Captcha** loesen
4. Fertig — den Rest macht die VM: Token nach `~/.config/ki-os/claude-token.env`
   (Mode 600), Hinweisfenster schliesst sich von selbst

**Warum nicht vollautomatisch?** Bis Juli 2026 war es das. Seit claude.ai ein
unsichtbares hCaptcha vor die OAuth-Bestaetigung schiebt, kann kein Skript den
Schritt mehr abschliessen — das ist ja der Zweck eines Captchas. Die VM
uebernimmt weiterhin alles davor und danach; sie braucht dich nur fuer diesen
einen Klick, dafuer dann ein Jahr lang nicht mehr.

Selbst anstossen (statt auf den Cockpit-Button zu warten):

```bash
ki-os-setup-token --assist    # im noVNC-Terminal auf der VM
```

Der Watcher `ki-os-relogin@<user>` startet das ausserdem von selbst, sobald du
im noVNC bist und noch kein Token existiert.

**Fuer `claude remote-control` zaehlt dieser Token NICHT** — Remote Control
nutzt die **Geraete-Anmeldung** (Full-Scope-OAuth via `claude auth login`).
Beide entstehen aus demselben claude.ai-Login, sind aber getrennte Token-Typen:
die Geraete-Anmeldung (Desktop-App / claude.ai-Code-Zugriff auf die VM) bleibt
am 30-Tage-Rhythmus, die geplanten Aufgaben nicht. Im Cockpit unter
**System → „Anmeldung & Zugaenge"** siehst du beide nebeneinander — mit Konto
und Ablaufdatum — und kannst die Geraete-Anmeldung dort auch **vor** dem
Ablauf per Knopf erneuern („Jetzt neu anmelden").

Die VM sourct `~/.config/ki-os/claude-token.env` automatisch aus `~/.profile`
**und** `~/.bashrc` — `.profile` deckt Login-/headless-Sessions (Scheduler),
`.bashrc` interaktive Terminals ab. Die Datei ist seit 08/2026 ein Symlink in
den Konto-Store `~/.config/ki-os/accounts/<konto>/`; der Token landet
ausschliesslich dort, nie im Hub-Repo.

**Mehrere Konten** (z.B. geplante Aufgaben auf einem eigenen Konto, damit sie
sich das Session-Limit nicht mit deiner Desktop-Nutzung teilen): Cockpit →
System → „Anmeldung & Zugaenge" → „Konto hinzufuegen" — der gefuehrte Ablauf
meldet dich im VM-Chrome ab, du meldest dich mit dem neuen Konto an, den Rest
macht die VM. **Wichtig:** danach im VM-Chrome wieder mit deinem Alltagskonto
anmelden (die Abschlussmeldung erinnert dich daran).

Rotieren (selten noetig — z.B. wenn der Token ungueltig wird):
`ki-os-setup-token --force` bzw. `--assist`, wenn ein Captcha dazwischenkommt.
Konten anzeigen/umschalten: `ki-os-setup-token list` / `switch <konto>`.

## Sicherheit

- `.env` ist gitignored — keine Sorge, dass du sie versehentlich commitest.
- Keys nie in Slack/Mail/Tickets posten — falls passiert, sofort rotieren
  (im jeweiligen Dienst Keys widerrufen + neu generieren).
- Wenn dein Admin dir Keys gibt: nicht im Klartext per Mail, sondern via
  geschuetztem Kanal (1Password Shared, Bitwarden Send, Verschluesseltes ZIP).
