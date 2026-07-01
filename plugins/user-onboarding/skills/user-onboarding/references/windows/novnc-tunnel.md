# noVNC-Tunnel als Scheduled Task (Windows)

**Pflicht-Bestandteil** des Setups (Schritt 7 in `SKILL.md`) — einer der
drei festen Autostarts (noVNC-Tunnel, Cockpit-Tunnel, Mutagen-Sync).

`ki-os-vm` ist der feste SSH-Alias (vom Skill gesetzt, keine Auswahl).

## Wozu

Auf der VM laeuft pro Mitarbeiter ein eigenes virtuelles Display mit
headed Chrome. noVNC macht dieses Display im Browser sichtbar — dort
laufen alle Browser-Logins, und der Agent-Browser ist live zu sehen und
zu bedienen.

noVNC bindet auf der VM nur an `127.0.0.1:<NOVNC_PORT>` (Schema
`6080 + (UID - 1000)`, steht in `~/.config/ki-os/display.env` auf der VM).
Der Task haelt einen Background-SSH-Tunnel `6080:127.0.0.1:<NOVNC_PORT>`.

URL: `http://localhost:6080/vnc.html?resize=scale` — beim Verbinden das noVNC-Passwort
eingeben (`ssh ki-os-vm 'cat ~/.config/ki-os/vnc.pass'`).

Die beiden Ports duerfen NICHT verwechselt werden: `$localPort` ist der feste
*lokale* Port `6080` (bei allen Mitarbeitern gleich). `$novncPort`
(`<NOVNC_PORT>`) ist der *VM-seitige, pro-User* Port aus `display.env` — nur
beim ersten User (UID 1000) ist der ebenfalls `6080`, danach `6081`, `6082`, …
Wer hier faelschlich `6080` einsetzt, tunnelt auf das Display eines **anderen**
Users (durch dessen noVNC-Passwort geschuetzt, aber das falsche Display).
Exakten Wert holen: `ssh ki-os-vm 'grep "^NOVNC_PORT=" ~/.config/ki-os/display.env | cut -d= -f2'`.

## Setup

Identisches **liveness-guarded** Muster wie der Cockpit-Tunnel
(`cockpit-scheduledtask.md`) — ein 2-Min-Watchdog ruft ein Guard-Skript auf,
das `ssh` nur startet, wenn der lokale Port noch nicht lauscht. Nur Name +
Ports anders:

```powershell
$taskName  = "ki-os-vm-novnc-tunnel"
$novncPort = "<NOVNC_PORT>"   # aus display.env, z.B. "6081"
$localPort = "6080"
$sshHost   = "ki-os-vm"
$sshExe    = "C:\Windows\System32\OpenSSH\ssh.exe"

$binDir = "$env:USERPROFILE\.local\bin"
New-Item -ItemType Directory -Path $binDir -Force | Out-Null

# 1) Guard-Skript: startet ssh NUR, wenn der lokale Port nicht schon lauscht.
#    (Warum kein blinder Respawn: cockpit-scheduledtask.md -> "Warum diese
#    Options" — blind respawnen leakt SSH-Sessions auf der VM.)
$guard = "$binDir\$taskName.ps1"
@"
`$ErrorActionPreference = 'SilentlyContinue'
if (Get-NetTCPConnection -LocalPort $localPort -State Listen) { exit 0 }
Start-Process -WindowStyle Hidden -FilePath '$sshExe' -ArgumentList @(
    '-N','-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=15',
    '-o','ServerAliveCountMax=3','-o','ConnectTimeout=10','-o','TCPKeepAlive=yes',
    '-o','StrictHostKeyChecking=accept-new',
    '-L','${localPort}:127.0.0.1:$novncPort','$sshHost')
"@ | Set-Content -Path $guard -Encoding ASCII

# 2) Unsichtbarer VBS-Launcher: ruft das Guard-Skript fensterlos auf.
$vbs = "$binDir\$taskName.vbs"
$psCall = 'powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{0}""' -f $guard
$line = 'CreateObject("WScript.Shell").Run "{0}", 0, False' -f $psCall
Set-Content -Path $vbs -Value $line -Encoding ASCII

$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbs`""

# Trigger: beim Login + alle 2 Min als Watchdog (fuehrt das Guard-Skript aus).
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
# -RepetitionDuration ist Pflicht: ohne sie bleibt die Duration leer und der Task
# feuert auf Win11 24H2 (Build 26100) nur EINMAL -> Watchdog tot.
# NICHT [TimeSpan]::MaxValue: der Task Scheduler lehnt das mit HRESULT 0x80041318
# (out of range) ab (real auf Win11 24H2, 2026-06-20). -Days 9999 (P9999D,
# ~27 Jahre) ist akzeptiert + effektiv unendlich, repetiert dauerhaft alle 2 Min.
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 2) `
    -RepetitionDuration (New-TimeSpan -Days 9999)).Repetition

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
# Arg-Formate ('-L 6080:...' Space UND '-L','6080:...' Array).
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

## Verifikation

```powershell
Get-ScheduledTask -TaskName "ki-os-vm-novnc-tunnel" | Get-ScheduledTaskInfo
Get-NetTCPConnection -LocalPort 6080 -State Listen

Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:6080/vnc.html?resize=scale" `
    -TimeoutSec 3 | Select-Object -ExpandProperty StatusCode
# erwartet: 200
```

Dann im Browser `http://localhost:6080/vnc.html?resize=scale` oeffnen → "Connect" →
noVNC-Passwort eingeben → VM-Desktop sichtbar (leer/grau ist okay,
solange kein Chrome laeuft).

## Warum diese Options

Siehe `cockpit-scheduledtask.md` → "Warum diese Options" — gilt 1:1
(liveness-guarded statt blind-respawn, unsichtbarer VBS-Launcher,
gehaertetes `ssh -N -L`). Insbesondere die ⚠️-Warnung dort: den Guard
**nicht** durch einen blinden 2-Min-`ssh`-Respawn ersetzen — das leakt
SSH-Sessions auf der VM.

## Deinstallation

```powershell
Stop-ScheduledTask -TaskName "ki-os-vm-novnc-tunnel" -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "ki-os-vm-novnc-tunnel" -Confirm:$false
Remove-Item "$env:USERPROFILE\.local\bin\ki-os-vm-novnc-tunnel.ps1","$env:USERPROFILE\.local\bin\ki-os-vm-novnc-tunnel.vbs" -ErrorAction SilentlyContinue
```

## Copy & Paste (Clipboard)

Copy & Paste laeuft **nahtlos** ueber die System-Zwischenablage — kopiere unter
Windows (`Strg+C`) und fuege auf der VM ein (`Strg+V`) und umgekehrt. Kein
Sidebar-Panel noetig.

**Voraussetzungen (alle bei diesem Setup erfuellt):**

- **Chrome oder Edge** als lokaler Browser. Firefox unterstuetzt die noetige
  Clipboard-API nicht und faellt auf das manuelle Sidebar-Panel zurueck
  (siehe unten) — fuer nahtloses Copy&Paste Chrome/Edge nutzen.
- Zugriff ueber `http://localhost:6080` (der SSH-Tunnel macht es zum
  *secure context* — kein HTTPS noetig).
- Beim ersten Mal fragt der Browser nach **Clipboard-Berechtigung** →
  zulassen. Danach laeuft es automatisch, sobald das noVNC-Bild fokussiert ist.

Moeglich wird das, weil die VM ein aktuelles noVNC (master, mit automatischer
Clipboard-Synchronisation) unter `/opt/novnc` ausliefert; das per apt
verfuegbare noVNC 1.3 kann das noch nicht. VM-seitig brueckt zusaetzlich der
`ki-os-autocutsel@<user>`-Dienst die zwei X11-Clipboards (PRIMARY/Markieren ↔
CLIPBOARD), damit auch reines Markieren auf der VM in der Zwischenablage landet.

**Fallback (Firefox):** Sidebar oeffnen → Clipboard-Icon → Text ins Feld
einfuegen bzw. von dort kopieren.

## Troubleshooting

| Symptom | Loesung |
|---------|---------|
| Browser laedt `http://localhost:6080/vnc.html?resize=scale` nicht | Tunnel lauscht? `Get-NetTCPConnection -LocalPort 6080 -State Listen`; sonst Task neu anstossen: `Start-ScheduledTask -TaskName ki-os-vm-novnc-tunnel` |
| Copy & Paste geht nicht | (1) Chrome/Edge statt Firefox nutzen. (2) Clipboard-Berechtigung erteilt? Im Schloss-Symbol der Adressleiste pruefen. (3) Erst ins noVNC-Bild klicken (Fokus), dann kopieren. (4) Nach einem noVNC-Update einmal frisch laden (Cache). Kommt VM→Windows nichts an: `ssh ki-os-vm systemctl status ki-os-autocutsel@<VM_USER>` — Admin kontaktieren |
| Port 6080 lokal belegt | `Get-NetTCPConnection -LocalPort 6080 -State Listen` — fremden Prozess beenden. **Hinweis:** Solange etwas auf 6080 lauscht, startet der Guard bewusst keinen neuen Tunnel |
| Seite laedt, "Failed to connect to server" | Meist lokaler Tunnel tot + alte Seite aus dem Browser-Cache. (1) `Start-ScheduledTask -TaskName ki-os-vm-novnc-tunnel`. (2) Alten Tab schliessen, Seite mit Strg+F5 neu laden. (3) Erst dann: VM-Service vom Admin pruefen lassen — `ssh ki-os-vm systemctl status ki-os-novnc@<VM_USER>` |
| Passwort wird abgelehnt | Frisch auslesen: `ssh ki-os-vm 'cat ~/.config/ki-os/vnc.pass'` |
| "channel ... open failed" | `<NOVNC_PORT>` falsch — Wert aus `display.env` neu pruefen, Task neu registrieren |
| `0x800710E0` als TaskResult | `-LogonType Interactive` setzen (siehe Setup) |
| Viele tote SSH-Sessions auf der VM | Alter blind-respawn-Task (vor 2026-06-18) noch aktiv → Task per Setup oben neu registrieren + Admin terminiert die Altlasten einmalig |
| Bild wirkt gezoomt / wird beschnitten | Scaling fehlt — der VM-Desktop ist fix 1920x1080. URL immer mit `?resize=scale` oeffnen; `http://localhost:6080/` leitet automatisch dorthin um. Hintergrund: Ubuntu liefert noVNC 1.3, dessen `defaults.json`-Mechanismus erst ab 1.4 greift. Alternativ noVNC-Seitenleiste → Settings → Scaling Mode → "Local Scaling" |
