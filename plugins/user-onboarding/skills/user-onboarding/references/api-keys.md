# API-Keys (auf der VM eintragen)

Nach abgeschlossenem Onboarding loggst du dich per `ssh <SSH_ALIAS>` ein
(Default `ki-os-vm`) und befuellst — falls dein Hub das vorsieht — die
`.env`-Datei in deinem Workspace mit den noetigen API-Keys.

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
ssh <SSH_ALIAS>
# auf der VM:
ki-os-auth gws auth login        # Google Workspace (Drive, Gmail, Calendar, Docs, ...)
ki-os-auth gh auth login         # GitHub CLI
```

Waehrenddessen den noVNC-Tab offen halten und den Login dort
durchklicken. (Der fruehere lokale `vm-oauth`-Helper ist obsolet.)

## Claude-Code-Auth

`claude` selbst loggt sich mit deinem persoenlichen Claude Max/Pro Account
ein. **Long-lived Tokens** (`CLAUDE_CODE_OAUTH_TOKEN`) reichen NICHT fuer
`claude remote-control` — der Service lehnt sie als "inference-only" ab.

Seit Claude Code 2.x laeuft der Login ueber einen **Paste-Code-Flow** mit
gehosteter Callback-URL — kein Wrapper noetig:

```bash
ssh <SSH_ALIAS>
# auf der VM:
claude auth login
# URL aus dem Terminal in deinen LOKALEN Browser kopieren,
# bei Anthropic einloggen, angezeigten Code zurueck ins Terminal pasten.
```

### Long-lived Token fuer headless/interaktive Sessions — laeuft AUTOMATISCH

Damit deine **normalen** `claude`-Sessions (interaktiv im noVNC-Terminal,
Scheduler/headless) ohne Re-Login laufen, brauchst du einen Long-lived,
inference-only Token. **Du musst dafuer nichts tun ausser dich in claude.ai
einloggen** (genau der Login, den du im noVNC-Browser ohnehin machst): die VM
erzeugt den Token danach **selbst** und legt ihn sicher ab.

Im Hintergrund erkennt der Watcher `ki-os-relogin@<user>`, dass du eingeloggt
bist, ruft `ki-os-setup-token` auf (automatisiert `claude setup-token` ueber den
VM-Chrome, klickt den Consent selbst) und schreibt den Token nach
`~/.config/ki-os/claude-token.env` (Mode 600). Das passiert **einmalig** je User;
liegt schon ein Token da, bleibt alles unangetastet.

**Fuer `claude remote-control` zaehlt dieser Token NICHT** — Remote Control nutzt
den Full-Scope-OAuth-Login (`claude auth login`, der bei Ablauf selbst-heilt).
Beide entstehen aus demselben claude.ai-Login, sind aber getrennte Token-Typen.

Die VM sourct `~/.config/ki-os/claude-token.env` automatisch aus `~/.profile`
**und** `~/.bashrc` — `.profile` deckt Login-/headless-Sessions (Scheduler),
`.bashrc` interaktive Terminals ab. Der Token (gueltig ~1 Jahr) landet
ausschliesslich in dieser Datei, nie im Hub-Repo.

Manuell nachziehen/rotieren (selten noetig — z.B. wenn der Token mal ungueltig
wird): auf der VM `ki-os-setup-token --force` (claude.ai-Session muss leben).

## Sicherheit

- `.env` ist gitignored — keine Sorge, dass du sie versehentlich commitest.
- Keys nie in Slack/Mail/Tickets posten — falls passiert, sofort rotieren
  (im jeweiligen Dienst Keys widerrufen + neu generieren).
- Wenn dein Admin dir Keys gibt: nicht im Klartext per Mail, sondern via
  geschuetztem Kanal (1Password Shared, Bitwarden Send, Verschluesseltes ZIP).
