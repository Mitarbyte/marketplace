# noVNC-Tunnel als systemd-User-Service (Linux)

**Pflicht-Bestandteil** des Setups (Schritt 7 in `SKILL.md`) — einer der
drei festen Autostarts (noVNC-Tunnel, Cockpit-Tunnel, Mutagen-Sync).

`ki-os-vm` ist der feste SSH-Alias (keine Auswahl); der Unit-Name ist
entsprechend `ki-os-vm-novnc-tunnel.service`.

## Wozu

Auf der VM laeuft pro Mitarbeiter ein eigenes virtuelles Display mit
headed Chrome. noVNC macht dieses Display im Browser sichtbar — dort
laufen alle Browser-Logins, und der Agent-Browser ist live zu sehen und
zu bedienen.

noVNC bindet auf der VM nur an `127.0.0.1:<NOVNC_PORT>` (Schema
`6080 + (UID - 1000)`, steht in `~/.config/ki-os/display.env` auf der VM).
Der Service haelt einen Background-SSH-Tunnel
`6080:127.0.0.1:<NOVNC_PORT>`.

URL: `http://localhost:6080/vnc.html?resize=scale` — beim Verbinden das noVNC-Passwort
eingeben (`ssh ki-os-vm 'cat ~/.config/ki-os/vnc.pass'`).

Die beiden Ports duerfen NICHT verwechselt werden: die **linke** `6080` im
`-L 6080:127.0.0.1:<NOVNC_PORT>` ist der feste *lokale* Port (bei allen
Mitarbeitern gleich). Die **rechte** Seite `<NOVNC_PORT>` ist der *VM-seitige,
pro-User* Port aus `display.env` — nur beim ersten User (UID 1000) ist der
ebenfalls `6080`, danach `6081`, `6082`, … Wer hier faelschlich `6080`
einsetzt, tunnelt auf das Display eines **anderen** Users (durch dessen
noVNC-Passwort geschuetzt, aber das falsche Display).

## Setup

Datei: `~/.config/systemd/user/ki-os-vm-novnc-tunnel.service`

```ini
[Unit]
Description=SSH-Tunnel zum Hub-VM noVNC (ki-os-vm)
After=network-online.target
Wants=network-online.target
# Nie aufgeben: ohne dies parkt systemd die Unit nach einer Fehlstart-Serie
# (z.B. Netz beim Aufwachen noch nicht da) dauerhaft im "failed"-Zustand
# ("start request repeated too quickly") — dann bleibt der Tunnel tot,
# obwohl die VM laengst wieder erreichbar ist. 0 = Rate-Limit aus.
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/bin/ssh -N \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -o ConnectTimeout=10 \
    -o TCPKeepAlive=yes \
    -o StrictHostKeyChecking=accept-new \
    -L 6080:127.0.0.1:<NOVNC_PORT> \
    ki-os-vm
Restart=always
RestartSec=15

[Install]
WantedBy=default.target
```

`<NOVNC_PORT>` NICHT raten, sondern den exakten Wert aus `display.env` holen
(die linke `6080` im `-L` bleibt unveraendert):

```bash
NOVNC_PORT=$(ssh ki-os-vm 'grep "^NOVNC_PORT=" ~/.config/ki-os/display.env | cut -d= -f2')
echo "VM-seitiger noVNC-Port dieses Users: ${NOVNC_PORT:?display.env fehlt — Admin kontaktieren}"
```

Diesen Wert fuer `<NOVNC_PORT>` in der Unit-Zeile (`ExecStart`) oben einsetzen.

Aktivieren:

```bash
systemctl --user daemon-reload
systemctl --user enable --now ki-os-vm-novnc-tunnel.service

# Status
systemctl --user status ki-os-vm-novnc-tunnel.service

# Logs
journalctl --user -u ki-os-vm-novnc-tunnel.service -f
```

**Linger nicht vergessen** (einmalig, gilt fuer alle User-Services):

```bash
sudo loginctl enable-linger "$USER"
```

WSL2-Hinweis: siehe `cockpit-systemd.md` → "Linger aktivieren".

## Verifikation

```bash
curl -fsS -o /dev/null -w '%{http_code}\n' http://localhost:6080/vnc.html
# erwartet: 200
```

Dann im Browser `http://localhost:6080/vnc.html?resize=scale` oeffnen → "Connect" →
noVNC-Passwort eingeben → VM-Desktop sichtbar (leer/grau ist okay,
solange kein Chrome laeuft).

## Copy & Paste (Clipboard)

Copy & Paste laeuft **nahtlos** ueber die System-Zwischenablage — kopiere lokal
(`Strg+C`) und fuege auf der VM ein (`Strg+V`) und umgekehrt. Kein Sidebar-Panel
noetig.

**Voraussetzungen (alle bei diesem Setup erfuellt):**

- **Chrome oder Edge** als lokaler Browser. Firefox/Safari unterstuetzen die
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

**Fallback (Firefox/Safari):** Sidebar oeffnen → Clipboard-Icon → Text ins Feld
einfuegen bzw. von dort kopieren.

## Troubleshooting

| Symptom | Loesung |
|---------|---------|
| Browser laedt `http://localhost:6080/vnc.html?resize=scale` nicht | `systemctl --user status ki-os-vm-novnc-tunnel.service` + Journal pruefen |
| Copy & Paste geht nicht | (1) Chrome/Edge statt Firefox/Safari nutzen. (2) Clipboard-Berechtigung erteilt? Im Schloss-Symbol der Adressleiste pruefen. (3) Erst ins noVNC-Bild klicken (Fokus), dann kopieren. (4) Nach einem noVNC-Update einmal frisch laden (Cache). Kommt VM→lokal nichts an: `ssh ki-os-vm systemctl status ki-os-autocutsel@<VM_USER>` — Admin kontaktieren |
| Port 6080 lokal belegt | `ss -tlnp \| grep 6080` — fremden Prozess beenden |
| Seite laedt, "Failed to connect to server" | noVNC-Service auf der VM down → `ssh ki-os-vm systemctl status ki-os-novnc@<VM_USER>` — Admin kontaktieren |
| Passwort wird abgelehnt | Frisch auslesen: `ssh ki-os-vm 'cat ~/.config/ki-os/vnc.pass'` |
| "channel ... open failed" im Journal | `<NOVNC_PORT>` falsch — Wert aus `display.env` neu pruefen und Unit korrigieren |
| Bild wirkt gezoomt / wird beschnitten | Scaling fehlt — der VM-Desktop ist fix 1920x1080. URL immer mit `?resize=scale` oeffnen; `http://localhost:6080/` leitet automatisch dorthin um. Hintergrund: Ubuntu liefert noVNC 1.3, dessen `defaults.json`-Mechanismus erst ab 1.4 greift. Alternativ noVNC-Seitenleiste → Settings → Scaling Mode → "Local Scaling" |
