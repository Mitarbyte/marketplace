# SSH-Key + Config — Hintergrund und Troubleshooting

Key + `~/.ssh/config`-Eintrag schreibt `scripts/setup-ssh.sh` (macOS/Linux)
bzw. `scripts/setup-ssh.ps1` (Windows). Dieses Dokument erklärt die
Design-Entscheidungen und sammelt die Fehlerbilder.

## Der Host-Block (minimal, bewusst nicht mehr)

```
Host ki-os-vm
    HostName <VM_IP>
    User <VM_USER>
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 15
    ServerAliveCountMax 3
    ConnectTimeout 10
    TCPKeepAlive yes
```

- **Kein `ControlMaster`/`ControlPath`, keine `LocalForward`-/
  `RemoteForward`-Zeilen, kein Zwei-Alias-Konstrukt.** Die Tunnel laufen als
  eigene gehärtete Autostart-Prozesse mit `-L` (`references/tunnels.md`) —
  so bleibt die Config minimal und interaktive SSH-Sessions (Terminal,
  Desktop-App, VS Code) sind von den Tunneln vollständig entkoppelt.
- `ServerAliveInterval 15` / `CountMax 3` / `ConnectTimeout 10` /
  `TCPKeepAlive yes` gelten für **jede** Verbindung über den Alias — wichtig
  für **Mutagen**, das den Alias direkt als Transport nutzt: tote SSH-Session
  in ~45 s erkannt statt bis 180 s zu hängen.
- `IdentitiesOnly yes` verhindert `Too many authentication failures` (SSH
  probiert sonst alle Keys aus `~/.ssh/` durch).
- Das Setup-Skript **ersetzt** einen vorhandenen `ki-os-vm`-Block immer
  komplett durch diese Fassung — bewusst, damit Konfig-Drift nicht unbemerkt
  bleibt.

## Windows-Eigenheiten (im Skript berücksichtigt)

- **BOM-frei schreiben:** `Add-Content -Encoding utf8` (PowerShell 5.1)
  schreibt ein UTF-8-BOM an den Dateianfang, an dem manche ssh-Builds
  abbrechen (`no argument after keyword "\357\273\277"`). Deshalb
  `[IO.File]::WriteAllText` mit `UTF8Encoding($false)`.
- **Leere Passphrase versionssicher:** Windows PowerShell 5.1
  (Legacy-Arg-Passing) und PowerShell 7.2+ reichen einen leeren `-N`-Wert
  UNTERSCHIEDLICH an `ssh-keygen` weiter (5.1: `-N '""'`, 7.x: `-N ''`).
  Falsch herum entsteht ein Key mit der 2-Zeichen-Passphrase `""` — der
  Server akzeptiert den Public Key in der Probe-Phase, aber das Signieren
  scheitert im BatchMode → rätselhaftes `Permission denied (publickey)`.
  Das Skript verifiziert deshalb nach dem Generieren per
  `ssh-keygen -y -P <np>`.
- **ACL-Permissions:** Windows-OpenSSH bricht bei zu offenen Permissions von
  `config`/Private-Key mit `Bad owner or permissions` ab — das Skript
  repariert die ACLs per `icacls` (Inheritance aus, nur der eigene User).
- **Nativer OpenSSH-Client:** Alle SSH-/Tunnel-Schritte nutzen
  `C:\Windows\System32\OpenSSH\ssh.exe`. Git for Windows ist trotzdem
  Pflicht (Claude Code braucht die Git Bash), aber dessen `ssh.exe` nicht
  vor den nativen Client in den PATH stellen.
- **ssh-agent (optional):** `Set-Service ssh-agent -StartupType Automatic` +
  `Start-Service ssh-agent` (als Admin), dann `ssh-add`. Ohne Passphrase
  nicht nötig — ssh nimmt den Key über `IdentityFile`.

## Smoketest-Fehlerbilder

```bash
ssh -o BatchMode=yes ki-os-vm true   # Exit 0 = OK
```

| Fehlerbild | Bedeutung / Lösung |
|---|---|
| `Permission denied (publickey)` | Admin hat den Key noch nicht hinterlegt, oder falscher Key. Public Key (`~/.ssh/id_ed25519.pub`) erneut an den Admin schicken. Erzwingen: `ssh -i ~/.ssh/id_ed25519 ki-os-vm` |
| `ssh -v`: erst `Server accepts key`, dann `Permission denied` (Windows) | Key hat eine echte Passphrase (`-N`-Quoting-Problem) — Key neu generieren (`setup-ssh.ps1 -NewKey` nach dem Löschen), NEUEN Public Key schicken |
| `Connection refused` / `timed out` | VM nicht erreichbar — IP falsch oder Firewall. Admin fragen |
| `Host key verification failed` | Bei neuem VM-Image: `ssh-keygen -R <VM_IP>`, dann einmal `ssh ki-os-vm` manuell und Host-Key akzeptieren |
| `Bad owner or permissions` (Windows) | ACLs reparieren — `setup-ssh.ps1` erneut laufen lassen |
| `Too many authentication failures` | `IdentitiesOnly yes` fehlt → Config per Setup-Skript neu schreiben |
| `ssh: command not found` (Windows) | OpenSSH-Client fehlt → `scripts/check-prereqs.ps1` (braucht Admin) |

## fail2ban

Auf der VM läuft fail2ban: Nach 4 Fehlversuchen wird die IP für 1 h gesperrt.
Admin entsperrt mit `fail2ban-client set sshd unbanip <IP>`.

## Sicherheit

- Der **Public Key ist nicht geheim** — er darf per Slack/Mail geteilt
  werden (`references/ssh-pubkey-handoff.md` hat Vorlagen). Der Private Key
  (`~/.ssh/id_ed25519` ohne `.pub`) bleibt strikt lokal und wird nie
  ausgegeben oder geloggt.
- Die leere Passphrase ist Default (Autostarts brauchen den Key
  unbeaufsichtigt); der User kann nachträglich per `ssh-keygen -p` eine
  setzen — dann aber ssh-agent einrichten, sonst brechen die Tunnel.
