# Cockpit-Tunnel als Scheduled Task (Windows)

**Pflicht-Bestandteil** des Setups (Schritt 8 in `SKILL.md`) — einer der
drei festen Autostarts (noVNC-Tunnel, Cockpit-Tunnel, Mutagen-Sync).
Windows-Aequivalent zu macOS-LaunchAgent / Linux-systemd-User-Service.

`ki-os-vm` ist der Default-SSH-Alias. Bei abweichendem Alias den Task-Namen
und die SSH-Host-Referenz ersetzen.

## Wozu

Identisch zu macOS/Linux: ein Background-SSH-Tunnel
`3847:127.0.0.1:<COCKPIT_PORT>`, der nach Reboot/Logout automatisch wieder
hochkommt. URL: `http://localhost:3847`.

Der lokale Port ist fuer alle Mitarbeiter einheitlich `3847`. Nur
`<COCKPIT_PORT>` auf der VM ist pro User verschieden (Schema
`30000 + UID`, liefert `mitarbyte cockpit-port`).

## Setup

Das Muster ist **liveness-guarded**: ein 2-Min-Watchdog ruft ein kleines
Guard-Skript auf, das `ssh` nur startet, wenn der lokale Port noch **nicht**
lauscht. Laeuft der Tunnel, passiert nichts. Stirbt er, kommt er binnen
2 Min wieder. (Warum nicht blind respawnen: siehe "Warum diese Options".)

```powershell
$taskName    = "ki-os-vm-cockpit-tunnel"
$cockpitPort = "<COCKPIT_PORT>"   # von mitarbyte cockpit-port, z.B. "31001"
$localPort   = "3847"
$sshHost     = "ki-os-vm"
$sshExe      = "C:\Windows\System32\OpenSSH\ssh.exe"

$binDir = "$env:USERPROFILE\.local\bin"
New-Item -ItemType Directory -Path $binDir -Force | Out-Null

# 1) Guard-Skript: startet ssh NUR, wenn der lokale Port nicht schon lauscht.
#    Get-NetTCPConnection ist locale-unabhaengig (anders als netstat/ABHOEREN).
$guard = "$binDir\$taskName.ps1"
@"
`$ErrorActionPreference = 'SilentlyContinue'
if (Get-NetTCPConnection -LocalPort $localPort -State Listen) { exit 0 }
Start-Process -WindowStyle Hidden -FilePath '$sshExe' -ArgumentList @(
    '-N','-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=60',
    '-o','ServerAliveCountMax=3','-o','StrictHostKeyChecking=accept-new',
    '-L','${localPort}:127.0.0.1:$cockpitPort','$sshHost')
"@ | Set-Content -Path $guard -Encoding ASCII

# 2) Unsichtbarer VBS-Launcher: ruft das Guard-Skript fensterlos auf.
#    powershell.exe direkt als Task-Action wuerde unter -LogonType Interactive
#    kurz ein Konsolenfenster aufblitzen lassen; wscript.exe ist fensterlos.
$vbs = "$binDir\$taskName.vbs"
$psCall = 'powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{0}""' -f $guard
$line = 'CreateObject("WScript.Shell").Run "{0}", 0, False' -f $psCall
Set-Content -Path $vbs -Value $line -Encoding ASCII

$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbs`""

# Trigger: beim Login starten + alle 2 Min als Watchdog. Der 2-Min-Tick fuehrt
# das Guard-Skript aus (Listen-Check), NICHT blind ssh (Begruendung unten).
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
# -RepetitionDuration ist Pflicht: ohne sie bleibt die Duration leer und der Task
# feuert auf Win11 24H2 (Build 26100) nur EINMAL -> Watchdog tot.
# NICHT [TimeSpan]::MaxValue: der Task Scheduler lehnt das mit HRESULT 0x80041318
# (out of range) ab (real auf Win11 24H2, 2026-06-20). -Days 9999 (P9999D,
# ~27 Jahre) ist akzeptiert + effektiv unendlich, repetiert dauerhaft alle 2 Min.
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 2) `
    -RepetitionDuration (New-TimeSpan -Days 9999)).Repetition

# ExecutionTimeLimit 0 = kein 72h-Kill. RestartInterval >= 1 Minute (PT30S ist
# ungueltig -> HRESULT 0x80041318). IgnoreNew bleibt als harmloses Netz.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1)

$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

# Idempotent + Self-Healing: erst JEDEN Scheduled Task entfernen, der einen
# ssh -L auf DIESEN lokalen Port faehrt (egal wie benannt, inkl. der vom Task
# verlinkten .vbs/.ps1) — sonst ueberlebt ein alt/falsch benannter Blind-Task
# das Re-Setup und leakt weiter. Separator-Klasse [''",\s] matcht beide
# Arg-Formate ('-L 3847:...' Space UND '-L','3847:...' Array).
foreach ($t in Get-ScheduledTask) {
    $blob = ($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' '
    foreach ($fm in [regex]::Matches($blob, '([A-Za-z]:\\[^"'' ]+\.(?:vbs|ps1))')) {
        if (Test-Path $fm.Groups[1].Value) { $blob += ' ' + (Get-Content -Raw $fm.Groups[1].Value -ErrorAction SilentlyContinue) }
    }
    if ($blob -match ('-L[''",\s]+' + $localPort + ':127\.0\.0\.1:\d+')) {
        Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}
# Verwaiste ssh-Tunnel auf genau diesem Port beenden (Leak-Reste; Mutagen +
# interaktive SSH bleiben unberuehrt, da nach -L <localPort> gefiltert wird).
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match ('-L\s*' + $localPort + ':127\.0\.0\.1:') } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal | Out-Null

# Sofort starten
Start-ScheduledTask -TaskName $taskName
```

Pruefen:

```powershell
Get-ScheduledTask -TaskName "ki-os-vm-cockpit-tunnel" | Get-ScheduledTaskInfo

# Tunnel lauscht lokal?
Get-NetTCPConnection -LocalPort 3847 -State Listen

# Verbindung testen
Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:3847" `
    -TimeoutSec 3 | Select-Object -ExpandProperty StatusCode
```

## Warum diese Options

- **Liveness-Guard statt blindem Respawn** — der eigentliche Kern. Windows'
  "Restart on failure" (`-RestartCount`) greift zuverlaessig nur, wenn der
  Task *beim Start* scheitert. Stirbt ein langlaufender `ssh -N` spaeter
  (Netzwerkwechsel, Idle-Timeout, Standby), wertet Windows den Lauf oft als
  "completed" und startet **nicht** neu — der Tunnel bliebe dauerhaft tot.
  Deshalb der 2-Min-Repetition-Trigger. Er feuert aber **nicht** blind `ssh`,
  sondern das Guard-Skript: nur wenn der lokale Port frei ist, wird ein neuer
  Tunnel gestartet.

  > ⚠️ **Nicht** zum blinden Respawn zuruecksetzen (alte Variante:
  > 2-Min-Trigger startet direkt `ssh -N` und verlaesst sich auf
  > `ExitOnForwardFailure` als "Selbstheilung"). Das **leakt SSH-Sessions**:
  > jeder `ssh`-Start **authentifiziert sich zuerst** (die VM legt eine Session
  > an) und entdeckt den Port-Konflikt erst danach — der doppelte `ssh -N`
  > bleibt unter Windows haeufig als idle-Verbindung haengen statt sauber zu
  > sterben. Da der Client weiter `ServerAliveInterval`-Keepalives sendet, sieht
  > die VM die Verbindung als lebendig und kann sie via `ClientAliveInterval`
  > **nie** reapen. Ergebnis: +2 tote Sessions alle 2 Min (noVNC + Cockpit),
  > ueber Stunden **Tausende** — RAM laeuft voll, neue Verbindungen scheitern an
  > `MaxStartups` mit "banner exchange timeout". (In einem realen Fall:
  > ~1700 Leak-Sessions, 6,6 GB RAM.) Der Listen-Check verhindert genau das.

- **Unsichtbarer VBS-Launcher (`wscript.exe` → `powershell.exe -File guard.ps1`,
  Fensterstil 0)** — `powershell.exe`/`ssh.exe` sind Konsolen-Prozesse; direkt
  als Task-Action mit `-LogonType Interactive` poppt bei jedem Login/Tick ein
  Fenster auf. `wscript.exe` ist GUI-subsystem (selbst fensterlos) und startet
  alles versteckt. `-LogonType Interactive` bleibt — nicht-interaktive
  Logon-Typen (S4U/Password) liefern hier `0x800710E0`.
- `ssh -N` (no remote command), **NICHT** `-f` — der Tunnel forwarded nur;
  `Start-Process -WindowStyle Hidden` uebernimmt das Hintergrund-Detachen.
- `-o ExitOnForwardFailure=yes` — bei Port-Konflikt sofort beenden statt ohne
  Forward weiterzulaufen (zweite Verteidigungslinie hinter dem Guard).
- `-o ServerAliveInterval=60 -o ServerAliveCountMax=3` — Client-Keepalive,
  damit NAT-Idle-Timeout die *lebende* Verbindung nicht killt.
- `-ExecutionTimeLimit 0` — kein Zeitlimit; sonst killt Windows den Task nach
  dem 72-Stunden-Default. (Betrifft nur den fire-and-forget-Launcher.)
- `-RestartCount 999 -RestartInterval 1min` — harmloses Netz neben dem
  Watchdog. **Nicht unter 1 Minute** — sonst HRESULT 0x80041318.

## Logs

Wer SSH-Output braucht, redirected im Guard-Skript ueber `Start-Process`:

```powershell
# in guard.ps1 statt der reinen Start-Process-Zeile:
$log = "$env:USERPROFILE\AppData\Local\ki-os-vm\logs\cockpit-tunnel.log"
New-Item -ItemType Directory -Path (Split-Path $log) -Force | Out-Null
Start-Process -WindowStyle Hidden -FilePath '<sshExe>' -ArgumentList @(...) `
    -RedirectStandardError $log
```

## Deinstallation

```powershell
Stop-ScheduledTask -TaskName "ki-os-vm-cockpit-tunnel" -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "ki-os-vm-cockpit-tunnel" -Confirm:$false
Remove-Item "$env:USERPROFILE\.local\bin\ki-os-vm-cockpit-tunnel.ps1","$env:USERPROFILE\.local\bin\ki-os-vm-cockpit-tunnel.vbs" -ErrorAction SilentlyContinue
# Falls noch ein ssh-Tunnel laeuft:
Get-Process ssh -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*OpenSSH*' } | Stop-Process
```

## Troubleshooting

| Symptom | Loesung |
|---------|---------|
| Browser laedt `http://localhost:3847` nicht | Health-Check ist der **lauschende Port**, nicht der Task-State (der Task ist nach dem fire-and-forget-Start wieder `Ready`): `Get-NetTCPConnection -LocalPort 3847 -State Listen` muss eine Zeile zeigen; der ssh-Prozess taucht in `Get-Process ssh` auf. Sonst Task neu anstossen: `Start-ScheduledTask -TaskName <alias>-cockpit-tunnel` |
| Port 3847 lokal belegt | `Get-NetTCPConnection -LocalPort 3847 -State Listen` — alten v1-Tunnel oder fremden Prozess beenden (v1-Reste: `../migration-v1.md`). **Hinweis:** Solange irgendetwas auf 3847 lauscht, startet der Guard bewusst keinen neuen Tunnel |
| "channel ... open failed" in SSH-Log | VM-Cockpit-Service down → `ssh ki-os-vm systemctl status mitarbyte-cockpit@<VM_USER>` |
| Tunnel reconnected staendig | Server-Key geaendert → einmalig `ssh-keygen -R <VM_IP>` (PowerShell) + `ssh ki-os-vm` manuell, Host-Key akzeptieren |
| `0x800710E0` als TaskResult | Logon-Type falsch — `-LogonType Interactive` setzen (siehe oben) |
| Viele tote SSH-Sessions auf der VM | Alter blind-respawn-Task (vor 2026-06-18) noch aktiv → Task per Setup oben neu registrieren (ersetzt die Action) + Admin terminiert die Altlasten einmalig (`loginctl terminate-user <VM_USER>`) |
| Tunnel laeuft nicht nach Reboot | Pruefe ob User wirklich eingeloggt war — `AtLogOn`-Trigger feuert nur beim echten Windows-Login |
