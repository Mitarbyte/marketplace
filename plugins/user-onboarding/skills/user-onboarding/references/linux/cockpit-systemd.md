# Cockpit-Tunnel als systemd-User-Service (Linux)

**Pflicht-Bestandteil** des Setups (Schritt 8 in `SKILL.md`) — einer der
drei festen Autostarts (noVNC-Tunnel, Cockpit-Tunnel, Mutagen-Sync).

`ki-os-vm` ist der Default-SSH-Alias. Bei abweichendem Alias den Unit-Namen
`ki-os-vm-cockpit-tunnel.service` und die SSH-Host-Referenz entsprechend
ersetzen. Der Service-Name auf der VM bleibt unabhaengig davon
`mitarbyte-cockpit@<user>.service`.

## Wozu

Wie beim macOS-LaunchAgent: ein Background-SSH-Tunnel
`3847:127.0.0.1:<COCKPIT_PORT>`, der nach Reboot/Logout automatisch wieder
hochkommt. URL: `http://localhost:3847`.

Der lokale Port ist fuer alle Mitarbeiter einheitlich `3847`. Nur
`<COCKPIT_PORT>` auf der VM ist pro User verschieden (Schema
`30000 + UID`, liefert `mitarbyte cockpit-port`).

## Setup

Datei: `~/.config/systemd/user/ki-os-vm-cockpit-tunnel.service`

```ini
[Unit]
Description=SSH-Tunnel zum Hub-VM Cockpit (ki-os-vm)
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
    -L 3847:127.0.0.1:<COCKPIT_PORT> \
    ki-os-vm
Restart=always
RestartSec=15

[Install]
WantedBy=default.target
```

`<COCKPIT_PORT>` durch User-Port (z.B. `31001`) ersetzen.

Aktivieren:

```bash
systemctl --user daemon-reload
systemctl --user enable --now ki-os-vm-cockpit-tunnel.service

# Status
systemctl --user status ki-os-vm-cockpit-tunnel.service

# Logs
journalctl --user -u ki-os-vm-cockpit-tunnel.service -f
```

## Linger aktivieren

Damit systemd-User-Services auch ohne aktive Login-Session laufen:

```bash
sudo loginctl enable-linger "$USER"
```

Ohne Linger laeuft der Tunnel nur, solange du eingeloggt bist (TTY oder
SSH-Session zum lokalen Geraet).

**WSL2:** systemd muss aktiviert sein — in `/etc/wsl.conf`
`[boot]\nsystemd=true` setzen, dann in PowerShell `wsl --shutdown` und
neu einloggen. Achtung: WSL2-Services laufen nur, solange die
WSL2-Instanz laeuft.

## Deaktivieren

```bash
systemctl --user disable --now ki-os-vm-cockpit-tunnel.service
rm ~/.config/systemd/user/ki-os-vm-cockpit-tunnel.service
systemctl --user daemon-reload
```

## Troubleshooting

| Symptom | Loesung |
|---------|---------|
| `Failed to connect to bus` bei `systemctl --user` | systemd-User-Bus nicht aktiv (WSL2: systemd in `/etc/wsl.conf` aktivieren); sonst neu einloggen |
| Service crasht in Schleife | `journalctl --user -u ki-os-vm-cockpit-tunnel.service -n50` |
| Service laeuft, aber Browser laedt `localhost:3847` nicht | Falscher `<COCKPIT_PORT>` — `ssh ki-os-vm mitarbyte cockpit-port` und Wert pruefen |
| Port 3847 lokal belegt | Alten v1-Tunnel oder fremden Prozess pruefen: `ss -tlnp \| grep 3847` — v1-Reste per `../migration-v1.md` entfernen |
| Tunnel down nach Reboot | `loginctl enable-linger` vergessen |
