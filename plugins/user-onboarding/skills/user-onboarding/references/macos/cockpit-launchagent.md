# Cockpit-Tunnel als LaunchAgent (macOS)

**Pflicht-Bestandteil** des Setups (Schritt 8 in `SKILL.md`) — einer der
drei festen Autostarts (noVNC-Tunnel, Cockpit-Tunnel, Mutagen-Sync).

In den Beispielen unten steht `ki-os-vm` als Default-SSH-Alias und das
LaunchAgent-Label endet auf `ki-os-vm-cockpit`. Bei abweichendem Alias
beide Stellen ersetzen (Label muss eindeutig sein, falls der User mehrere
Hub-VMs konfiguriert).

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
        <string>/usr/bin/ssh</string>
        <string>-N</string>
        <string>-o</string><string>ExitOnForwardFailure=yes</string>
        <string>-o</string><string>ServerAliveInterval=60</string>
        <string>-o</string><string>ServerAliveCountMax=3</string>
        <string>-o</string><string>StrictHostKeyChecking=accept-new</string>
        <string>-L</string><string>3847:127.0.0.1:<COCKPIT_PORT></string>
        <string>ki-os-vm</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
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

- `ssh -N` (no remote command) — der Tunnel macht nichts ausser forwarden
- **NICHT** `-f` (fork to background) — launchd muss den Prozess tracken
- `KeepAlive.SuccessfulExit=false` — restart wenn Tunnel beendet
- `ThrottleInterval=30` — nicht zu eng restarten (vermeidet Spinning)
- `ExitOnForwardFailure=yes` — bei Port-Konflikt sofort beenden statt
  ohne Forward weiterlaufen
- `ServerAliveInterval 60` — alle 60s ein Keepalive-Paket, sodass Tunnel
  durch NAT-Idle-Timeouts nicht stirbt

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
