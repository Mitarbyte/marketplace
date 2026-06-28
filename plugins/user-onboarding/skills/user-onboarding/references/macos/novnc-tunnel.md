# noVNC-Tunnel als LaunchAgent (macOS)

**Pflicht-Bestandteil** des Setups (Schritt 7 in `SKILL.md`) — einer der
drei festen Autostarts (noVNC-Tunnel, Cockpit-Tunnel, Mutagen-Sync).

`ki-os-vm` ist der feste SSH-Alias (keine Auswahl); das LaunchAgent-Label
endet auf `ki-os-vm-novnc`.

## Wozu

Auf der VM laeuft pro Mitarbeiter ein eigenes virtuelles Display mit
headed Chrome. noVNC macht dieses Display im Browser sichtbar — dort
laufen alle Browser-Logins, und der Agent-Browser ist live zu sehen und
zu bedienen.

noVNC bindet auf der VM nur an `127.0.0.1:<NOVNC_PORT>` (Schema
`6080 + (UID - 1000)`, steht in `~/.config/ki-os/display.env` auf der VM).
Der LaunchAgent haelt einen Background-SSH-Tunnel
`6080:127.0.0.1:<NOVNC_PORT>`, der nach Reboot/Schlaf/Netzwechsel
automatisch wieder hochkommt.

URL: `http://localhost:6080/vnc.html?resize=scale` — beim Verbinden das noVNC-Passwort
eingeben (`ssh ki-os-vm 'cat ~/.config/ki-os/vnc.pass'`).

Der lokale Port ist fuer alle Mitarbeiter einheitlich `6080`. Nur
`<NOVNC_PORT>` auf der VM ist pro User verschieden.

## Setup

Datei: `~/Library/LaunchAgents/com.<mac-user>.ssh-tunnel.ki-os-vm-novnc.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.<mac-user>.ssh-tunnel.ki-os-vm-novnc</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>while true; do /usr/bin/ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=10 -o TCPKeepAlive=yes -o StrictHostKeyChecking=accept-new -L 6080:127.0.0.1:<NOVNC_PORT> ki-os-vm; sleep 5; done</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>StandardOutPath</key><string>/Users/<mac-user>/Library/Logs/ssh-tunnel-ki-os-vm-novnc.log</string>
    <key>StandardErrorPath</key><string>/Users/<mac-user>/Library/Logs/ssh-tunnel-ki-os-vm-novnc.err.log</string>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
```

`<NOVNC_PORT>` aus Schritt 6 von `SKILL.md` einsetzen (z.B. `6080` fuer
den ersten User, `6081` fuer den zweiten).

Aktivieren / deaktivieren (identische Sequenz wie beim Cockpit-Tunnel):

```bash
PLIST=~/Library/LaunchAgents/com.<mac-user>.ssh-tunnel.ki-os-vm-novnc.plist
LABEL=com.<mac-user>.ssh-tunnel.ki-os-vm-novnc

# Wenn schon geladen, erst rausbootstrappen — idempotent
launchctl bootout gui/$(id -u)/${LABEL} 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ${PLIST}
launchctl enable   gui/$(id -u)/${LABEL}

# Restart nach Config-Aenderung
launchctl kickstart -k gui/$(id -u)/${LABEL}

# Status pruefen
launchctl print gui/$(id -u)/${LABEL} | head -20
```

## Warum diese Options

Identisch zum Cockpit-Tunnel (siehe `cockpit-launchagent.md` → "Warum
diese Options"): launchd supervidiert einen nie endenden `bash`-Loop
(`while true; do ssh …; sleep 5; done`) statt `ssh` direkt — sonst **parkt
launchd den Job nach einer Serie schneller Fehlstarts dauerhaft** (typisch
nach Sleep/Wake) und der Tunnel kommt nicht wieder. Dazu `ssh -N` ohne `-f`,
`KeepAlive=true` als Backstop, `ThrottleInterval=30`, `ExitOnForwardFailure=yes`,
`ServerAliveInterval 15`/`ServerAliveCountMax 3` (~45s Tot-Erkennung),
`ConnectTimeout 10`, `TCPKeepAlive yes`.

## Verifikation

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' http://localhost:6080/vnc.html
# erwartet: 200
```

Dann im Browser `http://localhost:6080/vnc.html?resize=scale` oeffnen → "Connect" →
noVNC-Passwort eingeben → VM-Desktop sichtbar (leer/grau ist okay,
solange kein Chrome laeuft — der startet beim ersten `ki-os-open` /
Agent-Browser-Einsatz auf der VM).

## Logs

```
~/Library/Logs/ssh-tunnel-ki-os-vm-novnc.log
~/Library/Logs/ssh-tunnel-ki-os-vm-novnc.err.log
```

## Copy & Paste (Clipboard)

Copy & Paste laeuft **nahtlos** ueber die System-Zwischenablage — kopiere auf
dem Mac (`Cmd+C`) und fuege auf der VM ein (`Strg+V` in Chrome/Terminal) und
umgekehrt. Kein Sidebar-Panel noetig.

**Voraussetzungen (alle bei diesem Setup erfuellt):**

- **Chrome oder Edge** als lokaler Browser. Safari/Firefox unterstuetzen die
  noetige Clipboard-API nicht und fallen auf das manuelle Sidebar-Panel
  zurueck (siehe unten) — fuer nahtloses Copy&Paste Chrome/Edge nutzen.
- Zugriff ueber `http://localhost:6080` (der SSH-Tunnel macht es zum
  *secure context* — kein HTTPS noetig).
- Beim ersten Mal fragt der Browser nach **Clipboard-Berechtigung** →
  zulassen. Danach laeuft es automatisch, sobald das noVNC-Bild fokussiert ist.

Moeglich wird das, weil die VM ein aktuelles noVNC (master, mit automatischer
Clipboard-Synchronisation) unter `/opt/novnc` ausliefert; das per apt
verfuegbare noVNC 1.3 kann das noch nicht. VM-seitig brueckt zusaetzlich der
`ki-os-autocutsel@<user>`-Dienst die zwei X11-Clipboards (PRIMARY/Markieren ↔
CLIPBOARD), damit auch reines Markieren auf der VM in der Zwischenablage landet.

**Fallback (Safari/Firefox):** Sidebar oeffnen → Clipboard-Icon → Text ins Feld
einfuegen bzw. von dort kopieren.

## Troubleshooting

| Symptom | Loesung |
|---------|---------|
| Browser laedt `http://localhost:6080/vnc.html?resize=scale` nicht | LaunchAgent-Logs pruefen, ggf. `launchctl kickstart -k gui/$(id -u)/com.<mac-user>.ssh-tunnel.ki-os-vm-novnc` |
| Copy & Paste geht nicht | (1) Chrome/Edge statt Safari/Firefox nutzen. (2) Clipboard-Berechtigung erteilt? Im Schloss-Symbol der Adressleiste pruefen. (3) Erst ins noVNC-Bild klicken (Fokus), dann kopieren. (4) Nach einem noVNC-Update einmal frisch laden (Cache). Kommt VM→Mac nichts an: `ssh ki-os-vm systemctl status ki-os-autocutsel@<VM_USER>` — Admin kontaktieren |
| Port 6080 schon lokal belegt | `lsof -nP -iTCP:6080` — fremden Prozess beenden oder Admin fragen |
| Seite laedt, "Failed to connect to server" | noVNC-Service auf der VM down → `ssh ki-os-vm systemctl status ki-os-novnc@<VM_USER>` — Admin kontaktieren |
| Passwort wird abgelehnt | Frisch auslesen: `ssh ki-os-vm 'cat ~/.config/ki-os/vnc.pass'` — exakt eingeben (Gross/Klein) |
| "channel ... open failed" im Err-Log | `<NOVNC_PORT>` falsch — Wert aus `display.env` neu pruefen (Schritt 6) und Plist korrigieren |
| Bild eingefroren | Tunnel reconnected gerade — 30 s warten; sonst `launchctl kickstart -k ...` |
| Bild wirkt gezoomt / wird beschnitten | Scaling fehlt — der VM-Desktop ist fix 1920x1080. URL immer mit `?resize=scale` oeffnen; `http://localhost:6080/` leitet automatisch dorthin um. Hintergrund: Ubuntu liefert noVNC 1.3, dessen `defaults.json`-Mechanismus erst ab 1.4 greift. Alternativ noVNC-Seitenleiste → Settings → Scaling Mode → "Local Scaling" |
