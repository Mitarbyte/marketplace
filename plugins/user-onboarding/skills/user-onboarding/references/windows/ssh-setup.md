# SSH-Setup (Windows)

Detail-Anleitung fuer Schritt 3 + 4 aus `SKILL.md`. Native Windows-Variante
(PowerShell + Windows-OpenSSH).

`ki-os-vm` ist der feste SSH-Alias (vom Skill gesetzt, keine Auswahl).

Der **native Windows-OpenSSH** reicht fuer SSH + Tunnel vollstaendig:
ControlMaster wird nirgendwo mehr gebraucht (das brauchte nur das
obsolete `vm-oauth`), und die Tunnel laufen als Scheduled Tasks mit
`-L`. **Git for Windows ist trotzdem Pflicht** — nicht fuer SSH,
sondern weil Claude Code auf nativem Windows (Desktop-App wie CLI) die
Git Bash voraussetzt (Install: `winget install --id Git.Git -e`).
Dessen `ssh.exe` aber NICHT vor den Windows-OpenSSH in den PATH
stellen — alle SSH-/Tunnel-Schritte hier nutzen den nativen Client
(`C:\Windows\System32\OpenSSH\ssh.exe`).

## Voraussetzung: OpenSSH-Client

Bei Windows 10/11 normalerweise vorinstalliert:

```powershell
Get-Command ssh -ErrorAction SilentlyContinue
ssh -V
# vorhanden → fertig

# Fehlt → installieren (PowerShell als Administrator):
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

### ssh-agent (optional, empfohlen)

```powershell
# Einmalig, als Administrator
Set-Service -Name ssh-agent -StartupType Automatic
Start-Service ssh-agent
```

## SSH-Key erstellen

Standard-User-PowerShell (kein Admin noetig):

```powershell
$key = "$env:USERPROFILE\.ssh\id_ed25519"

# Pruefen
Test-Path $key
# True → bestehenden Key nutzen
# False → neu generieren

# Leere Passphrase VERSIONSSICHER uebergeben:
# Windows PowerShell 5.1 (Legacy-Arg-Passing) und PowerShell 7.2+ (Standard-
# Arg-Passing) reichen einen leeren -N-Wert UNTERSCHIEDLICH an ssh-keygen weiter:
#   - 5.1 :  -N '""'  ergibt die echte Leer-Passphrase
#   - 7.x :  -N ''    ergibt die echte Leer-Passphrase
# Falsch herum baut ssh-keygen einen Key mit der 2-Zeichen-Passphrase «""».
# Symptom: Der Server akzeptiert den Public Key in der Probe-Phase, aber das
# Signieren scheitert in BatchMode → «Permission denied (publickey)» beim Connect.
$np = if ($PSVersionTable.PSVersion.Major -ge 7) { '' } else { '""' }

# Neu generieren (ohne Passphrase — User kann nachtraeglich per 'ssh-keygen -p' setzen)
ssh-keygen -t ed25519 -C "<email>" -f $key -N $np
```

**Pflicht-Verifikation** — der Private Key MUSS ohne Passphrase nutzbar sein.
Faengt jede Fehl-Quoting-Variante sofort ab, statt sie erst beim SSH-Connect
als raetselhaftes `Permission denied` auftauchen zu lassen:

```powershell
# -P $np vermeidet einen interaktiven Passphrase-Prompt (kein Haengen):
# Bei einem korrekt passphrasenlosen Key ignoriert ssh-keygen -y das -P und
# liefert den Public Key (Exit 0). Schlaegt es fehl, ist der Key verschluesselt.
$null = ssh-keygen -y -P $np -f $key 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "OK — Key hat eine leere Passphrase (BatchMode-tauglich)."
} else {
    Write-Warning @"
Der erzeugte Key hat NICHT die erwartete leere Passphrase (Quoting-Problem).
Key loeschen und exakt mit dem Block oben neu generieren:
  Remove-Item "$key", "$key.pub" -Force
Danach den NEUEN Public Key an den Admin schicken — der alte ist ungueltig.
"@
}
```

Public-Key in die Zwischenablage:

```powershell
Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub" | Set-Clipboard
Write-Host "Public Key in der Zwischenablage. Schick ihn an deinen Admin."
```

Alternativ, falls `Set-Clipboard` nicht verfuegbar (sehr alte PowerShell):

```powershell
Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub" | clip.exe
```

## Key in ssh-agent laden (optional)

```powershell
ssh-add "$env:USERPROFILE\.ssh\id_ed25519"
```

Ohne Passphrase (Default in diesem Skill) ist das nicht zwingend noetig —
ssh nimmt den Key dann ueber `IdentityFile` aus der Config.

## ~/.ssh/config — der komplette Eintrag

Auf Windows liegt die SSH-Config unter `%USERPROFILE%\.ssh\config` (ohne
Datei-Endung).

> **BOM-Hinweis:** `Add-Content -Encoding utf8` (PowerShell 5.1) schreibt
> ein UTF-8-BOM an den Dateianfang, an dem manche ssh-Builds (z.B. eine
> evtl. installierte Git-Bash-ssh) abbrechen. Deshalb die Config
> grundsaetzlich **BOM-frei** schreiben (`[IO.File]::WriteAllText` mit
> `UTF8Encoding($false)`), wie unten.

Pruefen, ob der Host schon existiert:

```powershell
$cfg = "$env:USERPROFILE\.ssh\config"
Test-Path $cfg
Select-String -Path $cfg -Pattern "^Host ki-os-vm$" -Quiet 2>$null
# True → existiert (User fragen, ob ueberschrieben werden soll;
#   enthaelt der Block v1-Zeilen wie RemoteForward/ControlMaster oder
#   gibt es einen Host ki-os-vm-mux → immer ersetzen, siehe ../migration-v1.md)
```

Block BOM-frei schreiben (`<VM_IP>` / `<VM_USER>` ersetzen):

```powershell
$sshDir = "$env:USERPROFILE\.ssh"
$cfg = "$sshDir\config"
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null

$block = @"
Host ki-os-vm
    HostName <VM_IP>
    User <VM_USER>
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 15
    ServerAliveCountMax 3
    ConnectTimeout 10
    TCPKeepAlive yes
"@ -replace "`r`n", "`n"

# BOM-frei schreiben (NICHT Add-Content -Encoding utf8 verwenden!)
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($cfg, $block, $enc)
```

Das ist der **komplette** Eintrag — bewusst KEIN
`ControlMaster`/`ControlPath`, KEIN Zwei-Alias-Konstrukt (`-mux`), KEINE
`LocalForward`-/`RemoteForward`-Zeilen. Die Tunnel (noVNC, Cockpit)
laufen als eigene Scheduled Tasks mit `-L` (siehe `novnc-tunnel.md` +
`cockpit-scheduledtask.md`). `IdentitiesOnly yes` verhindert
`Too many authentication failures`.

**Wichtig — ACL-Permissions:** Windows-OpenSSH ist pingelig bei den
Permissions von `~/.ssh/config` und den Private-Keys. Wenn `ssh` mit
"Bad owner or permissions" abbricht, ACLs reparieren:

```powershell
$keys = @("$env:USERPROFILE\.ssh\id_ed25519", "$env:USERPROFILE\.ssh\config")
foreach ($f in $keys) {
    icacls $f /inheritance:r
    icacls $f /grant:r "$($env:USERNAME):(F)"
    icacls $f /remove "BUILTIN\Users" "Everyone" "NT AUTHORITY\Authenticated Users" 2>$null
}
```

## Smoketest

```powershell
ssh -o BatchMode=yes ki-os-vm true; if ($LASTEXITCODE -eq 0) { "OK" } else { "FAIL" }
```

- `OK`: Verbindung steht.
- `Permission denied (publickey)`: Admin hat den Key noch nicht hinterlegt
  oder falscher Key. Public-Key (`~/.ssh/id_ed25519.pub`) erneut an den
  Admin schicken. **Sonderfall:** Zeigt `ssh -v` erst `Server accepts key`
  und dann `Permission denied`, ist der Key trotz Hinterlegung
  passphrasen-geschuetzt (Signieren scheitert im BatchMode) — das ist das
  Quoting-Problem aus dem Generieren-Schritt. Verifikation oben laufen
  lassen, Key neu generieren, NEUEN Public Key schicken.
- `Connection refused / timed out`: VM nicht erreichbar (IP falsch oder
  Firewall). Admin fragen.
- `Host key verification failed`: bei erstem Connect fragt SSH nach dem
  Host-Key — mit `yes` bestaetigen. Bei neuem VM-Image:
  `ssh-keygen -R <VM_IP>` und erneut.
- `Bad owner or permissions`: ACLs reparieren (siehe oben).

## fail2ban-Bann

Auf der VM laeuft fail2ban: nach 4 Fehlversuchen wird die IP fuer 1 h
gesperrt. Admin entsperrt mit `fail2ban-client set sshd unbanip <IP>`.

## Troubleshooting

| Symptom | Loesung |
|---------|---------|
| `ssh: command not found` | OpenSSH-Client nicht installiert → `Add-WindowsCapability` siehe oben |
| `Permission denied (publickey)` | Public-Key nochmal an Admin schicken; `ssh -i $env:USERPROFILE\.ssh\id_ed25519 ki-os-vm` zum Erzwingen |
| `ssh -v`: erst `Server accepts key`, dann `Permission denied` | Key hat eine echte Passphrase (Quoting beim `-N`) → Signieren scheitert im BatchMode. Verifikation aus "SSH-Key erstellen" laufen lassen, Key neu generieren, NEUEN Public Key schicken |
| `ssh-keygen -y` haengt / fragt nach Passphrase | Key ist passphrasen-geschuetzt (`-N`-Quoting) — beim Aufruf `-P $np` mitgeben bzw. Key neu generieren |
| `Bad owner or permissions on ...config` | `icacls`-Block oben anwenden |
| `no argument after keyword "\357\273\277"` | UTF-8-BOM in der config → BOM-frei neu schreiben (siehe oben) |
| `getsockname failed: Not a socket` | v1-Altlast: `ControlMaster`-Zeilen stehen noch in der Config → Block durch die minimale Fassung ersetzen (`../migration-v1.md`) |
| `Host key verification failed` | `ssh-keygen -R <VM_IP>`; neu verbinden |
| `Too many authentication failures` | `IdentitiesOnly yes` fehlt im Block → Config wie oben neu schreiben |
