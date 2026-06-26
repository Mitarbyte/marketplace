# SSH-Setup (Linux)

Detail-Anleitung fuer Schritt 3 + 4 aus `SKILL.md`.

`ki-os-vm` ist der Default-SSH-Alias. Bei abweichendem Alias alle Vorkommen
ersetzen.

Identisch zu macOS bis auf:

- Zwischenablage: statt `pbcopy` → `xclip -selection clipboard` (X11) oder
  `wl-copy` (Wayland). Falls keines installiert: `cat ~/.ssh/id_ed25519.pub`
  und manuell kopieren.

## SSH-Key erstellen

```bash
# Pruefen
test -f ~/.ssh/id_ed25519 && echo "EXISTS" || echo "MISSING"

# Generieren
ssh-keygen -t ed25519 -C "<email>" -f ~/.ssh/id_ed25519 -N ""
```

Public-Key in die Zwischenablage:

```bash
# X11
if command -v xclip >/dev/null; then
    cat ~/.ssh/id_ed25519.pub | xclip -selection clipboard
    echo "Public Key in Zwischenablage."
# Wayland
elif command -v wl-copy >/dev/null; then
    cat ~/.ssh/id_ed25519.pub | wl-copy
    echo "Public Key in Zwischenablage."
else
    echo "Keine Clipboard-CLI gefunden — Public Key (kopier ihn manuell):"
    cat ~/.ssh/id_ed25519.pub
fi
```

## ~/.ssh/config — der komplette Eintrag

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
touch ~/.ssh/config
chmod 600 ~/.ssh/config

grep -q "^Host ki-os-vm$" ~/.ssh/config 2>/dev/null && echo "EXISTS" || cat >> ~/.ssh/config <<EOF

Host ki-os-vm
    HostName <VM_IP>
    User <VM_USER>
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
EOF
```

Das ist der **komplette** Eintrag — bewusst KEIN
`ControlMaster`/`ControlPath`/`ControlPersist` (brauchte nur das obsolete
`vm-oauth`) und KEINE `LocalForward`-/`RemoteForward`-Zeilen (die Tunnel
laufen als eigene gehaertete systemd-User-Services mit `-L`, siehe
`novnc-tunnel.md` + `cockpit-systemd.md`).

Wenn ein bestehender Block noch solche Zeilen enthaelt: durch die
minimale Fassung ersetzen — siehe `../migration-v1.md`.

## Smoketest

```bash
ssh -o BatchMode=yes ki-os-vm true && echo "OK" || echo "FAIL"
```

Fehlerbilder (Permission denied / Timeout / Host-Key) wie in der
macOS-Referenz beschrieben (`../macos/ssh-setup.md` → Smoketest).
