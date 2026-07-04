# =============================================================================
# setup-tunnels.ps1 — beide gehaerteten SSH-Tunnel-Autostarts (natives Windows)
#
#   noVNC:   lokal 6080 -> VM 127.0.0.1:<NOVNC_PORT>
#   Cockpit: lokal 3847 -> VM 127.0.0.1:<COCKPIT_PORT>
#
# Muster: liveness-guarded Scheduled Task — ein 2-Min-Watchdog ruft ein
# Guard-Skript, das ssh NUR startet, wenn der lokale Port noch nicht lauscht
# (blinder Respawn leakt SSH-Sessions auf der VM). Self-Healing: EIN Durchlauf
# ueber alle Tasks entfernt vorher jeden alt/falsch benannten Tunnel-Task auf
# denselben Ports (inhaltsbasiert). Haertungs-Begruendung: references/tunnels.md.
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
if (-not (Test-Path $sshExe)) { Write-Host "FAIL: $sshExe fehlt — check-prereqs.ps1 laufen lassen."; exit 1 }

$binDir = Join-Path $env:USERPROFILE '.local\bin'
New-Item -ItemType Directory -Path $binDir -Force | Out-Null

$tunnels = @(
    @{ Name = 'ki-os-vm-novnc-tunnel';   LocalPort = 6080; RemotePort = $NovncPort },
    @{ Name = 'ki-os-vm-cockpit-tunnel'; LocalPort = 3847; RemotePort = $CockpitPort }
)

# --- Cleanup (Self-Healing): EIN Scan ueber alle Tasks fuer BEIDE Ports --------
# Entfernt jeden Task, der einen ssh -L auf einen unserer lokalen Ports faehrt
# (egal wie benannt, inkl. der vom Task verlinkten .vbs/.ps1-Dateien).
# Separator-Klasse [''",\s] matcht beide Arg-Formate ('-L 6080:...' und
# '-L','6080:...').
$portAlt = ($tunnels | ForEach-Object { $_.LocalPort }) -join '|'
$taskPattern   = '-L[''",\s]+(' + $portAlt + '):127\.0\.0\.1:\d+'
$orphanPattern = '-L\s*('       + $portAlt + '):127\.0\.0\.1:'

foreach ($t in (Get-ScheduledTask -ErrorAction SilentlyContinue)) {
    $blob = ($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' '
    foreach ($fm in [regex]::Matches($blob, '([A-Za-z]:\\[^"'' ]+\.(?:vbs|ps1))')) {
        if (Test-Path $fm.Groups[1].Value) {
            $blob += ' ' + (Get-Content -Raw $fm.Groups[1].Value -ErrorAction SilentlyContinue)
        }
    }
    if ($blob -match $taskPattern) {
        Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "CLEANUP: alter Tunnel-Task '$($t.TaskName)' entfernt."
    }
}

# Verwaiste ssh-Tunnel auf genau diesen Ports beenden (Leak-Reste; Mutagen +
# interaktive SSH bleiben unberuehrt, da nach -L <localPort> gefiltert wird).
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match $orphanPattern } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# --- Tasks registrieren ---------------------------------------------------------
foreach ($tun in $tunnels) {
    $taskName  = $tun.Name
    $localPort = $tun.LocalPort
    $vmPort    = $tun.RemotePort

    # 1) Guard-Skript: startet ssh NUR, wenn der lokale Port nicht schon lauscht.
    $guard = Join-Path $binDir "$taskName.ps1"
    @"
`$ErrorActionPreference = 'SilentlyContinue'
if (Get-NetTCPConnection -LocalPort $localPort -State Listen) { exit 0 }
Start-Process -WindowStyle Hidden -FilePath '$sshExe' -ArgumentList @(
    '-N','-o','ExitOnForwardFailure=yes','-o','ServerAliveInterval=15',
    '-o','ServerAliveCountMax=3','-o','ConnectTimeout=10','-o','TCPKeepAlive=yes',
    '-o','StrictHostKeyChecking=accept-new',
    '-L','${localPort}:127.0.0.1:$vmPort','ki-os-vm')
"@ | Set-Content -Path $guard -Encoding ASCII

    # 2) Unsichtbarer VBS-Launcher (wscript = GUI-Subsystem, kein Konsolen-Popup)
    $vbs = Join-Path $binDir "$taskName.vbs"
    $psCall = 'powershell.exe -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{0}""' -f $guard
    $line = 'CreateObject("WScript.Shell").Run "{0}", 0, False' -f $psCall
    Set-Content -Path $vbs -Value $line -Encoding ASCII

    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""

    # Trigger: beim Login + alle 2 Min als Watchdog. -RepetitionDuration ist
    # Pflicht (sonst feuert der Task auf Win11 24H2 nur EINMAL). NICHT
    # [TimeSpan]::MaxValue (HRESULT 0x80041318) — P9999D ist akzeptiert und
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

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Principal $principal | Out-Null

    Start-ScheduledTask -TaskName $taskName
    Write-Host "OK: Scheduled Task $taskName (lokal $localPort -> VM $vmPort)"
}

# --- Kurz-Verifikation -----------------------------------------------------------
Start-Sleep -Seconds 6
foreach ($tun in $tunnels) {
    if (Get-NetTCPConnection -LocalPort $tun.LocalPort -State Listen -ErrorAction SilentlyContinue) {
        Write-Host "VERIFY_OK: localhost:$($tun.LocalPort) lauscht ($($tun.Name))"
    } else {
        Write-Host "VERIFY_PENDING: localhost:$($tun.LocalPort) lauscht noch nicht — der 2-Min-Watchdog zieht den Tunnel nach; sonst references/tunnels.md -> Troubleshooting."
    }
}
