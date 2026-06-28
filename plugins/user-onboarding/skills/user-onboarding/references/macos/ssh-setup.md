# SSH-Setup (macOS)

Detail-Anleitung fuer Schritt 3 + 4 aus `SKILL.md`.

Im Folgenden steht `ki-os-vm` als Default-SSH-Alias. Wenn der User in
Schritt 2 einen anderen Alias gewaehlt hat, muessen alle Vorkommen
ersetzt werden.

## SSH-Key erstellen

```bash
# Pruefen ob schon vorhanden
test -f ~/.ssh/id_ed25519 && echo "EXISTS: bestehenden Key nutzen" || echo "MISSING: neu generieren"

# Neu generieren (ohne Passphrase — User kann nachtraeglich via 'ssh-keygen -p' setzen)
ssh-keygen -t ed25519 -C "<email>" -f ~/.ssh/id_ed25519 -N ""
```

Public-Key in die Zwischenablage:

```bash
cat ~/.ssh/id_ed25519.pub | pbcopy
echo "Public Key in der Zwischenablage. Schick ihn an deinen Admin."
```

Falls `pbcopy` nicht verfuegbar (selten): `cat ~/.ssh/id_ed25519.pub` und
Inhalt manuell kopieren.

## ~/.ssh/config — der komplette Eintrag

Vor dem Append pruefen, ob der Host schon existiert:

```bash
grep -q "^Host ki-os-vm$" ~/.ssh/config 2>/dev/null && echo "EXISTS" || echo "MISSING"
```

Wenn `MISSING`: Block anhaengen (mit fuehrendem Newline, falls die Datei
nicht leer ist und nicht mit Newline endet):

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/config
chmod 600 ~/.ssh/config

# Falls letztes Zeichen kein Newline, eines anhaengen
[ -s ~/.ssh/config ] && [ "$(tail -c1 ~/.ssh/config)" != "" ] && echo >> ~/.ssh/config

cat >> ~/.ssh/config <<EOF

Host ki-os-vm
    HostName <VM_IP>
    User <VM_USER>
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 15
    ServerAliveCountMax 3
    ConnectTimeout 10
    TCPKeepAlive yes
EOF
```

`ServerAliveInterval 15` / `ServerAliveCountMax 3` / `ConnectTimeout 10` /
`TCPKeepAlive yes` gelten fuer **jede** Verbindung ueber den Alias — also auch
fuer **Mutagen** (nutzt `ki-os-vm` direkt als Transport). Damit erkennt Mutagen
eine tote SSH-Session in ~45s und reconnectet, statt bis zu 180s in
"Connecting…" zu haengen. (Die noVNC-/Cockpit-Tunnel setzen dieselben Optionen
zusaetzlich direkt auf der `ssh`-Kommandozeile.)

Das ist der **komplette** Eintrag. Bewusst NICHT enthalten:

- `ControlMaster`/`ControlPath`/`ControlPersist` — wurde nur vom
  obsoleten `vm-oauth` gebraucht
- `LocalForward`/`RemoteForward` — die Tunnel (noVNC, Cockpit) laufen
  als eigene gehaertete Autostart-Prozesse mit `-L`
  (siehe `novnc-tunnel.md` + `cockpit-launchagent.md`)

Wenn ein bestehender `Host ki-os-vm`-Block noch solche Zeilen enthaelt
(oder ein `Host ki-os-vm-mux`-Block existiert): Block durch die minimale
Fassung oben ersetzen — siehe `../migration-v1.md`.

## Smoketest

```bash
ssh -o BatchMode=yes ki-os-vm true && echo "OK" || echo "FAIL"
```

- `OK`: Verbindung steht.
- `Permission denied (publickey)`: Admin hat den Key noch nicht hinterlegt
  oder es ist ein falscher Key. Public Key (`~/.ssh/id_ed25519.pub`) erneut
  an den Admin schicken.
- `Connection refused / Connection timed out`: VM nicht erreichbar (IP falsch
  oder Firewall blockt). Admin fragen, ob Public-IP stimmt und Port 22 offen
  ist.
- `Host key verification failed`: bei erstem Connect fragt SSH nach dem
  Host-Key — mit `yes` bestaetigen. Falls die VM neu provisioniert wurde:
  `ssh-keygen -R <VM_IP>` und erneut verbinden.

## fail2ban-Bann

Auf der VM laeuft fail2ban: nach 4 Fehlversuchen wird die IP fuer 1 h
gesperrt. Falls passiert: Admin entsperrt mit
`fail2ban-client set sshd unbanip <IP>`.

## Troubleshooting

| Symptom | Loesung |
|---------|---------|
| `Permission denied (publickey)` | Public-Key nochmal an Admin schicken, sicherstellen dass `~/.ssh/id_ed25519` der richtige Private-Key ist (`-i` zum Erzwingen: `ssh -i ~/.ssh/id_ed25519 ki-os-vm`) |
| `Host key verification failed` | `ssh-keygen -R <VM_IP>`; neu verbinden |
| `Connection timed out` | VM-IP falsch oder Firewall blockt Port 22 → Admin fragen |
| `Too many authentication failures` | SSH probiert alle Keys aus `~/.ssh/` durch → `IdentitiesOnly yes` steht im Block (siehe oben) — pruefen, ob der richtige Block greift |
