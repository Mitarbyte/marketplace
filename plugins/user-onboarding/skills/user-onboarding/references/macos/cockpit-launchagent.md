# Cockpit-Tunnel als LaunchAgent (macOS)

**Pflicht-Bestandteil** des Setups (Schritt 8 in `SKILL.md`) — einer der
drei festen Autostarts (noVNC-Tunnel, Cockpit-Tunnel, Mutagen-Sync).

In den Beispielen unten steht der feste SSH-Alias `ki-os-vm`; das
LaunchAgent-Label endet entsprechend auf `ki-os-vm-cockpit`.

## Wozu

Das Cockpit (Scheduler, Token-Usage, Skills) laeuft auf der VM nur auf
`127.0.0.1:<COCKPIT_PORT>`. Der LaunchAgent haelt einen Background-SSH-
Tunnel `3847:127.0.0.1:<COCKPIT_PORT>`, der nach Reboot/Schlaf/Netzwechsel
automatisch wieder hochkommt. URL: `http://localhost:3847`.

Der lokale Port ist fuer alle Mitarbeiter einheitlich `3847` (jeder hat
seinen eigenen Laptop). Nur `<COCKPIT_PORT>` auf der VM ist pro User
verschieden (Schema `30000 + UID`, liefert `mitarbyte cockpit-port`).

## Setup

Datei: `~/Library/LaunchAgents/com.<mac-user>.ssh-tunnel.ki-os-vm-cockpit.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.<mac-user>.ssh-tunnel.ki-os-vm-cockpit</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>while true; do /usr/bin/ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=10 -o TCPKeepAlive=yes -o StrictHostKeyChecking=accept-new -L 3847:127.0.0.1:<COCKPIT_PORT> ki-os-vm; sleep 5; done</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>StandardOutPath</key><string>/Users/<mac-user>/Library/Logs/ssh-tunnel-ki-os-vm-cockpit.log</string>
    <key>StandardErrorPath</key><string>/Users/<mac-user>/Library/Logs/ssh-tunnel-ki-os-vm-cockpit.err.log</string>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
```

`<COCKPIT_PORT>` ist der User-spezifische Port aus `mitarbyte cockpit-port`
(z.B. `31001` fuer UID 1001).

Aktivieren / deaktivieren (modern, `bootstrap`/`bootout` — `load -w`
ist deprecated):

```bash
PLIST=~/Library/LaunchAgents/com.<mac-user>.ssh-tunnel.ki-os-vm-cockpit.plist
LABEL=com.<mac-user>.ssh-tunnel.ki-os-vm-cockpit

# Wenn schon geladen, erst rausbootstrappen — idempotent
launchctl bootout gui/$(id -u)/${LABEL} 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ${PLIST}
launchctl enable   gui/$(id -u)/${LABEL}

# Restart nach Config-Aenderung
launchctl kickstart -k gui/$(id -u)/${LABEL}

# Status pruefen
launchctl print gui/$(id -u)/${LABEL} | head -20

# Komplett entfernen
launchctl bootout gui/$(id -u)/${LABEL}
rm ${PLIST}
```

Der `user-onboarding`-Skill nutzt genau diese Sequenz, damit ein zweiter
Skill-Run sauber neu laedt statt eine zweite Instanz zu erzeugen.

## Warum diese Options

**Der LaunchAgent supervidiert bewusst NICHT `ssh` direkt, sondern einen
nie endenden `bash`-Loop** (`while true; do ssh …; sleep 5; done`). Das ist
der entscheidende Punkt gegen das wiederkehrende Problem „Tunnel bricht nach
einer Zeit ab und kommt nicht wieder":

- Laesst man launchd direkt `ssh` mit `KeepAlive` ueberwachen, **parkt launchd
  den Job nach einer Serie schneller Fehlstarts dauerhaft** (typisch nach
  Sleep/Wake, wenn das Netz beim Aufwachen noch nicht steht und `ssh` in <1s
  mit „Can't assign requested address" abbricht). Danach versucht launchd den
  Job **gar nicht mehr** zu starten — der Tunnel bleibt tot, obwohl die VM
  laengst wieder erreichbar ist. (Real reproduziert 2026-06-28: alle drei
  Tunnel ueber Nacht geparkt bei „last exit code = 255 / not running", VM
  erreichbar; `launchctl kickstart` belebt sofort.)
- Der `bash`-Loop ist **ein einziger langlebiger Prozess** — launchd sieht nie
  schnelle Exits, kann also nie parken. Stirbt `ssh` (Netzwechsel, Sleep,
  VM-Neustart), startet der Loop es innerhalb von ~5s neu. Das ist die macOS-
  Entsprechung des liveness-guarded Windows-Watchdogs.
- `KeepAlive=true` ist nur noch Backstop: falls der `bash`-Loop selbst je
  sterben sollte, startet launchd ihn neu.

Die `ssh`-Optionen im Loop:

- `ssh -N` (no remote command) — der Tunnel macht nichts ausser forwarden
- **NICHT** `-f` (fork to background) — der Loop muss `ssh` im Vordergrund
  halten, sonst kehrt er sofort zum `sleep` zurueck und spawnt Dutzende
  Tunnel
- `ServerAliveInterval 15` + `ServerAliveCountMax 3` — ein totes Link wird in
  **~45s** erkannt (frueher 60×3 = 180s; in diesem Fenster blieb der lokale
  Port gebunden, leitete aber ins Leere → „verbunden, aber eingefroren")
- `ConnectTimeout 10` — ein fehlgeschlagener Verbindungsaufbau (VM kurz weg)
  kehrt schnell zurueck, der Loop probiert sofort erneut
- `ExitOnForwardFailure=yes` — bei belegtem Port sofort beenden + neu
  versuchen (raeumt einen halbtoten Listener auf)
- `TCPKeepAlive=yes` — zusaetzlich gegen NAT-Idle-Timeouts
- `ThrottleInterval=30` — Backstop-Throttle, falls der Loop doch crasht

## Logs

```
~/Library/Logs/ssh-tunnel-ki-os-vm-cockpit.log
~/Library/Logs/ssh-tunnel-ki-os-vm-cockpit.err.log
```

Bei Problemen erst hier reinschauen.

## Troubleshooting

| Symptom | Loesung |
|---------|---------|
| Browser laedt `http://localhost:3847` nicht | LaunchAgent-Logs pruefen, ggf. `launchctl kickstart -k gui/$(id -u)/com.<mac-user>.ssh-tunnel.ki-os-vm-cockpit` |
| Port 3847 schon lokal belegt | Alten v1-Tunnel (Port 13847) oder fremden Prozess pruefen: `lsof -nP -iTCP:3847` — v1-Reste per `../migration-v1.md` entfernen |
| "channel ... open failed" im Err-Log | VM-Cockpit-Service down → `ssh ki-os-vm systemctl status mitarbyte-cockpit@<VM_USER>` (der Service-Name wird vom VM-Provisioning so installiert) |
| Tunnel reconnected staendig | Server-IP/-Key geaendert → einmalig `ssh-keygen -R <VM_IP>` und `ssh ki-os-vm` manuell, Host-Key akzeptieren |
