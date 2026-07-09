# =============================================================================
# setup-tunnels.ps1 - gehaertete SSH-Tunnel-Autostarts (natives Windows)
#
#   noVNC:   lokal 6080 -> VM 127.0.0.1:<NOVNC_PORT>
#   Cockpit: lokal 3847 -> VM 127.0.0.1:<COCKPIT_PORT>
#
# Muster: EIN liveness-guarded Scheduled Task `ki-os-vm-watchdog` (mit Autor +
# Beschreibung, statt mehrerer anonym wirkender Einzel-Tasks) - sein
# 2-Min-Guard startet ssh NUR, wenn der lokale Port noch nicht lauscht
# (blinder Respawn leakt SSH-Sessions auf der VM), und haelt zusaetzlich den
# Mutagen-Daemon am Leben (no-op, bis setup-mutagen.ps1 gelaufen ist).
# Self-Healing: EIN Durchlauf ueber alle Tasks entfernt vorher jeden
# alt/falsch benannten Tunnel-/Daemon-Task (inhaltsbasiert) - inkl. der
# frueheren Einzel-Tasks ki-os-vm-{novnc,cockpit}-tunnel + mutagen-daemon.
# Haertungs-Begruendung: references/tunnels.md.
#
# PowerShell-5.1-kompatibel. Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File setup-tunnels.ps1 `
#       -NovncPort <VM_PORT> -CockpitPort <VM_PORT>
# =============================================================================
param(
    [Parameter(Mandatory = $true)][int]$NovncPort,
    [Parameter(Mandatory = $true)][int]$CockpitPort
)
$ErrorActionPreference = 'Stop'

$sshExe = 'C:\Windows\System32\OpenSSH\ssh.exe'
if (-not (Test-Path $sshExe)) { Write-Host "FAIL: $sshExe fehlt - check-prereqs.ps1 laufen lassen."; exit 1 }

$binDir = Join-Path $env:USERPROFILE '.local\bin'
New-Item -ItemType Directory -Path $binDir -Force | Out-Null

$taskName = 'ki-os-vm-watchdog'
$tunnels = @(
    @{ Label = 'noVNC';   LocalPort = 6080; RemotePort = $NovncPort },
    @{ Label = 'Cockpit'; LocalPort = 3847; RemotePort = $CockpitPort }
)

# --- Cleanup (Self-Healing): EIN Scan ueber alle Tasks --------------------------
# Entfernt jeden Task, der einen ssh -L auf einen unserer lokalen Ports ODER
# `mutagen daemon run` faehrt (egal wie benannt, inkl. der vom Task verlinkten
# .vbs/.ps1-Dateien) - faengt die frueheren Einzel-Tasks, beliebige Altlasten
# und den Watchdog selbst (wird gleich frisch registriert). Separator-Klasse
# [''",\s] matcht beide Arg-Formate ('-L 6080:...' und '-L','6080:...').
$portAlt = ($tunnels | ForEach-Object { $_.LocalPort }) -join '|'
$taskPattern   = '-L[''",\s]+(' + $portAlt + '):127\.0\.0\.1:\d+|mutagen(\.exe)?[''"\s]+daemon\s+run'
$orphanPattern = '-L\s*('       + $portAlt + '):127\.0\.0\.1:'
$fileRx        = '([A-Za-z]:\\[^"'' ]+\.(?:vbs|ps1))'

foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    $blob = ($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' '
    # Verlinkte Skripte REKURSIV einlesen (VBS-Launcher -> Guard-.ps1): der
    # ssh -L steht erst in der zweiten Stufe. Besucht-Set gegen Zyklen.
    $seen  = @{}
    $queue = New-Object System.Collections.Queue
    [regex]::Matches($blob, $fileRx) | ForEach-Object { $queue.Enqueue($_.Groups[1].Value) }
    while ($queue.Count -gt 0) {
        $p = $queue.Dequeue()
        if ($seen.ContainsKey($p) -or -not (Test-Path $p)) { continue }
        $seen[$p] = $true
        $content = [string](Get-Content -Raw $p -ErrorAction SilentlyContinue)
        $blob += ' ' + $content
        [regex]::Matches($content, $fileRx) | ForEach-Object { $queue.Enqueue($_.Groups[1].Value) }
    }
    if ($blob -match $taskPattern) {
        Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "CLEANUP: alter Task '$($t.TaskName)' entfernt."
    }
}

# Sicherheitsgurt zum Inhalts-Scan: die frueheren Einzel-Tasks zusaetzlich
# namensbasiert entfernen + deren Artefakte loeschen (Bestands-User).
foreach ($n in @('ki-os-vm-novnc-tunnel', 'ki-os-vm-cockpit-tunnel', 'mutagen-daemon')) {
    Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
}
foreach ($f in @('ki-os-vm-novnc-tunnel.ps1', 'ki-os-vm-novnc-tunnel.vbs',
                 'ki-os-vm-cockpit-tunnel.ps1', 'ki-os-vm-cockpit-tunnel.vbs',
                 'mutagen-daemon-hidden.vbs')) {
    Remove-Item (Join-Path $binDir $f) -ErrorAction SilentlyContinue
}

# Verwaiste ssh-Tunnel auf genau diesen Ports beenden (Leak-Reste; Mutagen +
# interaktive SSH bleiben unberuehrt, da nach -L <localPort> gefiltert wird).
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match $orphanPattern } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# --- Guard-Skript: startet nur, was fehlt -----------------------------------------
$guard = Join-Path $binDir "$taskName.ps1"
@"
# KI-OS-Watchdog - generiert von setup-tunnels.ps1, laeuft alle 2 Minuten.
`$ErrorActionPreference = 'SilentlyContinue'

# Tunnel: ssh NUR starten, wenn der lokale Port noch nicht lauscht
# (blinder Respawn leakt SSH-Sessions auf der VM).
if (-not (Get-NetTCPConnection -LocalPort 6080 -State Listen)) {
    Start-Process -WindowStyle Hidden -FilePath '$sshExe' -ArgumentList @(
        '-N','-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=15',
        '-o','ServerAliveCountMax=3','-o','ConnectTimeout=10','-o','TCPKeepAlive=yes',
        '-o','StrictHostKeyChecking=accept-new',
        '-L','6080:127.0.0.1:$NovncPort','ki-os-vm')
}
if (-not (Get-NetTCPConnection -LocalPort 3847 -State Listen)) {
    Start-Process -WindowStyle Hidden -FilePath '$sshExe' -ArgumentList @(
        '-N','-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=15',
        '-o','ServerAliveCountMax=3','-o','ConnectTimeout=10','-o','TCPKeepAlive=yes',
        '-o','StrictHostKeyChecking=accept-new',
        '-L','3847:127.0.0.1:$CockpitPort','ki-os-vm')
}

# Mutagen-Daemon: no-op, bis setup-mutagen.ps1 gelaufen ist. Prozess-Check
# spart Spawns; der Daemon-Lock macht selbst einen blinden Respawn leak-frei.
`$mutagen = Join-Path `$env:USERPROFILE '.local\bin\mutagen.exe'
if (-not (Test-Path `$mutagen)) { `$mutagen = (Get-Command mutagen).Source }
if (`$mutagen -and -not (Get-Process -Name mutagen)) {
    Start-Process -WindowStyle Hidden -FilePath `$mutagen -ArgumentList 'daemon','run'
}
"@ | Set-Content -Path $guard -Encoding ASCII

# Unsichtbarer VBS-Launcher (wscript = GUI-Subsystem, kein Konsolen-Popup)
$vbs = Join-Path $binDir "$taskName.vbs"
$psCall = 'powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{0}""' -f $guard
$line = 'CreateObject("WScript.Shell").Run "{0}", 0, False' -f $psCall
Set-Content -Path $vbs -Value $line -Encoding ASCII

# --- Task registrieren ------------------------------------------------------------
$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""

# Trigger: beim Login + alle 2 Min als Watchdog. -RepetitionDuration ist
# Pflicht (sonst feuert der Task auf Win11 24H2 nur EINMAL). NICHT
# [TimeSpan]::MaxValue (HRESULT 0x80041318) - P9999D ist akzeptiert und
# effektiv unendlich.
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 2) `
    -RepetitionDuration (New-TimeSpan -Days 9999)).Repetition

# ExecutionTimeLimit 0 = kein 72h-Kill. RestartInterval >= 1 Min (PT30S ->
# HRESULT 0x80041318).
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1)

# Nicht-interaktive Logon-Typen (S4U/Password) liefern 0x800710E0.
$principal = New-ScheduledTaskPrincipal `
    -UserId $env:USERNAME `
    -LogonType Interactive `
    -RunLevel Limited

# Beschreibung geht direkt ueber den -Description-Parameter (existiert). Autor
# NICHT ueber $task.RegistrationInfo.Author setzen: New-ScheduledTask liefert
# RegistrationInfo=$null, die Zuweisung crasht dann auf PS 5.1 -- und weil der
# Cleanup oben die Alt-Tasks schon entfernt hat, bliebe das Setup kaputt.
$desc = 'Haelt die KI-OS-Verbindungen am Leben: noVNC-Tunnel (localhost:6080), Cockpit-Tunnel (localhost:3847) und Mutagen-Sync-Daemon. Prueft alle 2 Minuten und startet nur, was fehlt. Eingerichtet vom user-onboarding-Skill; ein erneuter Skill-Lauf erneuert diesen Task.'

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description $desc | Out-Null

# Autor best-effort per XML-Roundtrip nachtragen (Register-ScheduledTask kennt
# keinen -Author-Parameter). Schlaegt das fehl, laeuft der Task trotzdem --
# er hat dann nur keinen Autor im Task Scheduler, ist aber voll funktional.
try {
    [xml]$xml = Export-ScheduledTask -TaskName $taskName
    $nsUri = $xml.DocumentElement.NamespaceURI
    # local-name()-XPath = namespace-agnostisch (Export setzt einen Default-NS).
    $reg = $xml.SelectSingleNode('/*[local-name()="Task"]/*[local-name()="RegistrationInfo"]')
    if (-not $reg) {
        $reg = $xml.CreateElement('RegistrationInfo', $nsUri)
        $xml.DocumentElement.InsertBefore($reg, $xml.DocumentElement.FirstChild) | Out-Null
    }
    # Windows setzt <Author> beim Register oft automatisch auf den erstellenden
    # User -> vorhandenen Knoten hart auf 'Mitarbyte' ueberschreiben statt nur
    # anlegen. Fehlt er, schema-konform VOR Version/Description/Documentation
    # einfuegen (registrationInfoType ist eine feste xs:sequence, sonst lehnt
    # Register-ScheduledTask -Xml die XML ab).
    $authorEl = $reg.SelectSingleNode('*[local-name()="Author"]')
    if (-not $authorEl) {
        $authorEl = $xml.CreateElement('Author', $nsUri)
        $anchor = $reg.SelectSingleNode('*[local-name()="Version" or local-name()="Description" or local-name()="Documentation"]')
        if ($anchor) { $reg.InsertBefore($authorEl, $anchor) | Out-Null }
        else { $reg.AppendChild($authorEl) | Out-Null }
    }
    $authorEl.InnerText = 'Mitarbyte'
    # Kein -User: der Principal (LogonType Interactive) steckt schon in der XML;
    # -User wuerde ihn ggf. auf Password/S4U umbiegen (0x800710E0).
    Register-ScheduledTask -TaskName $taskName -Xml $xml.OuterXml -Force | Out-Null
} catch {
    Write-Host "WARN: Autor 'Mitarbyte' nicht gesetzt ($($_.Exception.Message)) - Task laeuft trotzdem."
}

Start-ScheduledTask -TaskName $taskName
Write-Host "OK: Scheduled Task $taskName (noVNC lokal 6080 -> VM $NovncPort, Cockpit lokal 3847 -> VM $CockpitPort, Mutagen-Daemon sobald installiert)"

# --- Kurz-Verifikation -----------------------------------------------------------
Start-Sleep -Seconds 6
foreach ($tun in $tunnels) {
    if (Get-NetTCPConnection -LocalPort $tun.LocalPort -State Listen -ErrorAction SilentlyContinue) {
        Write-Host "VERIFY_OK: localhost:$($tun.LocalPort) lauscht ($($tun.Label))"
    } else {
        Write-Host "VERIFY_PENDING: localhost:$($tun.LocalPort) lauscht noch nicht - der 2-Min-Watchdog zieht den Tunnel nach; sonst references/tunnels.md -> Troubleshooting."
    }
}
