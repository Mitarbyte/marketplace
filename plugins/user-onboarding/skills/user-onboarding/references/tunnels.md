# noVNC- + Cockpit-Tunnel — Härtung, Hintergrund, Troubleshooting

**Gilt nur für tunnel-VMs.** Auf gateway-VMs (`ACCESS_MODE=gateway` in
Schritt 6) gibt es keine Tunnel — noVNC/Cockpit laufen über die
Gateway-URLs mit Firmen-Login; Alt-Tunnel entfernt
`setup-tunnels.sh --remove` / `setup-tunnels.ps1 -Remove`.

Die beiden Pflicht-Autostarts richtet `scripts/setup-tunnels.sh` (macOS/Linux)
bzw. `scripts/setup-tunnels.ps1` (Windows) ein — dieses Dokument erklärt das
**Warum** und sammelt die Troubleshooting-Tabellen.

| Tunnel | Lokal (fix, alle Mitarbeiter) | VM (pro User) | Zweck |
|---|---|---|---|
| noVNC | `6080` | `<NOVNC_PORT>` (Schema `6080 + UID − 1000`, aus `~/.config/ki-os/display.env`) | VM-Browser ansehen + bedienen: `http://localhost:6080/vnc.html?resize=scale` |
| Cockpit | `3847` | `<COCKPIT_PORT>` (Schema `30000 + UID`, liefert `mitarbyte cockpit-port`) | Cockpit-Web-UI: `http://localhost:3847` |

**Ports nicht verwechseln:** links steht immer der feste *lokale* Port, rechts
der *VM-seitige, pro-User* Wert. Nur beim ersten User (UID 1000) ist der
noVNC-Port ebenfalls `6080` — danach `6081`, `6082`, … Wer rechts fälschlich
`6080` einsetzt, tunnelt auf das Display eines **anderen** Users (durch dessen
noVNC-Passwort geschützt, aber das falsche Display).

## Backends pro OS

| OS | Backend | Artefakte |
|----|---------|-----------|
| macOS | LaunchAgents `com.<mac-user>.ssh-tunnel.ki-os-vm-{novnc,cockpit}` | `~/Library/LaunchAgents/*.plist`, Logs unter `~/Library/Logs/ssh-tunnel-ki-os-vm-*` |
| Linux | systemd-User-Services `ki-os-vm-{novnc,cockpit}-tunnel.service` | `~/.config/systemd/user/*.service`, Logs via `journalctl --user -u <unit>` |
| Windows | EIN gemeinsamer Scheduled Task `ki-os-vm-watchdog` (Autor `Mitarbyte` + Beschreibung; deckt beide Tunnel **und** den Mutagen-Daemon ab) | Guard `ki-os-vm-watchdog.ps1` + VBS-Launcher unter `%USERPROFILE%\.local\bin\` |

## Warum diese Härtung (nicht vereinfachen!)

Alle Varianten fahren dasselbe gehärtete
`ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15
-o ServerAliveCountMax=3 -o ConnectTimeout=10 -o TCPKeepAlive=yes` (~45 s
Tot-Erkennung statt 180 s). Der **kritische** Punkt — und die Ursache des
wiederkehrenden „Tunnel bricht ab und kommt nicht wieder" — ist die
Supervision: alle drei Supervisoren **parken** einen Job nach einer Serie
schneller Fehlstarts dauerhaft (typisch nach Sleep/Wake, wenn das Netz noch
nicht steht) — der Tunnel bleibt tot, obwohl die VM längst erreichbar ist.
Deshalb pro OS:

- **macOS:** Der LaunchAgent supervidiert NICHT `ssh` direkt, sondern einen
  nie endenden `bash`-Loop (`while true; do ssh …; sleep 5; done`). launchd
  sieht damit nie schnelle Exits → kann nie parken; stirbt `ssh`, baut der
  Loop es in ~5 s neu auf. `KeepAlive=true` ist nur Backstop für den Loop.
  (Real reproduziert 2026-06-28: drei direkt-`ssh`-LaunchAgents über Nacht
  geparkt bei „exit 255 / not running", VM erreichbar.) `ssh` ohne `-f` —
  der Loop muss `ssh` im Vordergrund halten, sonst spawnt er Dutzende Tunnel.
- **Linux:** `Restart=always` + **`StartLimitIntervalSec=0`** (Rate-Limit aus,
  sonst „start request repeated too quickly" → failed) + `RestartSec=15`.
- **Windows:** EIN 2-Min-Repetition-Watchdog (`ki-os-vm-watchdog`), der ein
  **liveness-guarded** Guard-Skript aufruft — es startet `ssh` pro Tunnel nur,
  wenn der lokale Port noch nicht lauscht, und den Mutagen-Daemon nur, wenn
  kein `mutagen`-Prozess läuft. Der periodische Watchdog umgeht das Parken,
  weil er alles unabhängig vom Supervisor-Zustand alle 2 Min neu zieht. Ein
  einzelner Task statt drei hält den Task Scheduler des Users übersichtlich;
  Autor + Beschreibung machen im UI sofort klar, wozu er da ist.

### ⚠️ Windows: niemals blind respawnen

Der 2-Min-Trigger darf **nicht** direkt `ssh` starten: jeder `ssh`-Start
authentifiziert sich zuerst (die VM legt eine Session an) und entdeckt den
Port-Konflikt erst danach — der doppelte `ssh -N` bleibt unter Windows häufig
als Idle-Verbindung hängen. Da der Client weiter Keepalives sendet, kann die
VM die Session nie reapen. Ergebnis: +2 tote Sessions alle 2 Min, über Stunden
**Tausende** — RAM läuft voll, neue Verbindungen scheitern an `MaxStartups`
(real: ~1700 Leak-Sessions, 6,6 GB RAM). Der Listen-Check im Guard verhindert
genau das.

Weitere Windows-Fallstricke (im Skript berücksichtigt):

- `-RepetitionDuration` ist Pflicht — ohne sie feuert der Task auf Win11 24H2
  nur EINMAL (toter Watchdog). **Nicht** `[TimeSpan]::MaxValue` (HRESULT
  `0x80041318`), sondern `P9999D` (~27 Jahre, effektiv unendlich).
- `RestartInterval` ≥ 1 Minute (PT30S → `0x80041318`).
- `-LogonType Interactive` — andere Logon-Typen liefern `0x800710E0`.
- VBS-Launcher (`wscript.exe`, Fensterstil 0) — sonst blitzt bei jedem
  Login/Tick ein Konsolenfenster auf.
- **Self-Healing:** `setup-tunnels.ps1` entfernt vor der Registrierung jeden
  Task, der einen `ssh -L` auf denselben lokalen Port ODER `mutagen daemon
  run` fährt (inhaltsbasiert, inkl. verlinkter `.vbs`/`.ps1`), und beendet
  verwaiste `ssh`-Tunnel auf diesen Ports — ein fehlerhaft konfigurierter
  Alt-Task heilt sich beim nächsten Skill-Lauf von selbst, und Bestands-Setups
  mit den früheren drei Einzel-Tasks (`ki-os-vm-{novnc,cockpit}-tunnel`,
  `mutagen-daemon`) werden automatisch auf den einen Watchdog konsolidiert.

## Nützliche Kommandos

```bash
# macOS — Status / Restart / Logs
launchctl print gui/$(id -u)/com.$(id -un).ssh-tunnel.ki-os-vm-novnc | head -20
launchctl kickstart -k gui/$(id -u)/com.$(id -un).ssh-tunnel.ki-os-vm-novnc
tail -50 ~/Library/Logs/ssh-tunnel-ki-os-vm-novnc.err.log

# Linux — Status / Restart / Logs
systemctl --user status ki-os-vm-novnc-tunnel.service
systemctl --user restart ki-os-vm-novnc-tunnel.service
journalctl --user -u ki-os-vm-novnc-tunnel.service -n 50
```

```powershell
# Windows — Health-Check ist der LAUSCHENDE PORT, nicht der Task-State
# (der Task ist nach dem fire-and-forget-Start wieder "Ready"):
Get-NetTCPConnection -LocalPort 6080 -State Listen
Start-ScheduledTask -TaskName ki-os-vm-watchdog
```

## Copy & Paste (noVNC-Clipboard)

Copy & Paste läuft **nahtlos** über die System-Zwischenablage (lokal `Cmd/Strg+C`
↔ VM `Strg+V`), Voraussetzungen:

- **Chrome oder Edge** als lokaler Browser (Safari/Firefox können die nötige
  Clipboard-API nicht → Fallback: noVNC-Sidebar → Clipboard-Panel).
- Zugriff über `http://localhost:6080` (der SSH-Tunnel macht es zum *secure
  context* — kein HTTPS nötig).
- Beim ersten Mal die **Clipboard-Berechtigung** im Browser zulassen; danach
  läuft es automatisch, sobald das noVNC-Bild fokussiert ist.

Möglich wird das durch das aktuelle noVNC (`/opt/novnc`, automatische
Clipboard-Synchronisation) auf der VM; zusätzlich brückt der
`ki-os-autocutsel@<user>`-Dienst die X11-Clipboards (PRIMARY ↔ CLIPBOARD).

## Troubleshooting

| Symptom | Lösung |
|---------|---------|
| Browser lädt `localhost:6080`/`3847` nicht | Backend prüfen (Kommandos oben); macOS: `kickstart -k`, Linux: `systemctl --user restart`, Windows: `Start-ScheduledTask`. Windows: solange irgendetwas auf dem Port lauscht, startet der Guard bewusst keinen neuen Tunnel |
| Port lokal schon belegt | macOS: `lsof -nP -iTCP:6080` · Linux: `ss -tlnp \| grep 6080` · Windows: `Get-NetTCPConnection -LocalPort 6080 -State Listen` — fremden Prozess beenden |
| Seite lädt, „Failed to connect to server" | Meist lokaler Tunnel tot + alte Seite aus dem Cache: Tunnel neu starten, Tab mit Strg+F5 neu laden. Sonst VM-Service down: `ssh ki-os-vm systemctl status ki-os-novnc@<VM_USER>` bzw. `mitarbyte-cockpit@<VM_USER>` — Admin kontaktieren |
| noVNC-Passwort wird abgelehnt | Frisch auslesen: `ssh ki-os-vm 'cat ~/.config/ki-os/vnc.pass'` — exakt eingeben (Groß/Klein) |
| „channel … open failed" im Log | VM-seitiger Port falsch — Werte mit `scripts/get-vm-values.sh` neu holen und `setup-tunnels` erneut laufen lassen |
| Copy & Paste geht nicht | (1) Chrome/Edge nutzen. (2) Clipboard-Berechtigung im Schloss-Symbol prüfen. (3) Erst ins noVNC-Bild klicken (Fokus). (4) Nach noVNC-Update einmal frisch laden. Kommt VM→lokal nichts an: `ssh ki-os-vm systemctl status ki-os-autocutsel@<VM_USER>` — Admin kontaktieren |
| Bild gezoomt / beschnitten | VM-Desktop ist fix 1920×1080 — URL immer mit `?resize=scale` öffnen (`http://localhost:6080/` leitet dorthin um); alternativ noVNC-Sidebar → Settings → Scaling Mode → „Local Scaling" |
| Bild eingefroren | Tunnel reconnectet gerade — 30 s warten, sonst Backend neu starten |
| Tunnel reconnectet ständig | Server-IP/-Key geändert → einmalig `ssh-keygen -R <VM_IP>`, dann `ssh ki-os-vm` manuell und Host-Key akzeptieren |
| Viele tote SSH-Sessions auf der VM (Windows) | Alter Blind-Respawn-Task noch aktiv → `setup-tunnels.ps1` erneut laufen lassen (räumt inhaltsbasiert auf) + Admin terminiert Altlasten einmalig (`loginctl terminate-user <VM_USER>`) |
| Tunnel läuft nach Reboot nicht (Windows) | `AtLogOn`-Trigger feuert nur beim echten Windows-Login — prüfen, ob der User eingeloggt war |
| Tunnel läuft nach Reboot nicht (Linux) | Linger fehlt: `sudo loginctl enable-linger $USER` |
| `0x800710E0` als TaskResult (Windows) | Logon-Type falsch — Skript erneut laufen lassen (`-LogonType Interactive`) |
