# Mutagen-Sync (Windows)

**Pflicht-Bestandteil** des Setups (Schritt 9 in `SKILL.md`) — einer der
drei festen Autostarts (noVNC-Tunnel, Cockpit-Tunnel, Mutagen-Sync).

`ki-os-vm` ist der feste SSH-Alias (vom Skill gesetzt, keine Auswahl).

> **Status-Hinweis:** Mutagen ist die beschlossene Architektur, auf
> Windows aber noch nicht im Kundenbetrieb verifiziert. Bei Problemen
> (Daemon startet nicht, Sync haengt nach Netzwechsel) → Admin
> informieren.

## Wozu

Identisch zur macOS-Referenz (`../macos/mutagen.md` → "Wozu"): echte
lokale Kopie des VM-Workspaces unter `%USERPROFILE%\KI-OS`, two-way,
reconnectet selbst, friert nicht ein. Ersetzt den frueheren
WinFsp/sshfs-win-Mount komplett (inkl. aller Mount-Workarounds).

Mutagen nutzt als Transport den installierten OpenSSH-Client und liest
`%USERPROFILE%\.ssh\config` — der `ki-os-vm`-Alias funktioniert direkt.

## 1. Installieren

Es gibt **kein offizielles winget-Paket** — Installation per
GitHub-Release-Zip nach `%USERPROFILE%\.local\bin`:

```powershell
$bin = "$env:USERPROFILE\.local\bin"
New-Item -ItemType Directory -Path $bin -Force | Out-Null

# Neueste windows_amd64-Release-URL ermitteln
$rel = Invoke-RestMethod -Uri "https://api.github.com/repos/mutagen-io/mutagen/releases/latest"
$url = ($rel.assets | Where-Object { $_.name -match 'windows_amd64.*\.zip$' -and $_.name -notmatch 'sidecar' })[0].browser_download_url

$zip = "$env:TEMP\mutagen.zip"
Invoke-WebRequest -Uri $url -OutFile $zip
Expand-Archive -Path $zip -DestinationPath $bin -Force
Remove-Item $zip

# PATH erweitern (User-Scope), falls noetig
$userPath = [Environment]::GetEnvironmentVariable('PATH','User')
if ($userPath -notlike "*$bin*") {
    [Environment]::SetEnvironmentVariable('PATH', "$bin;$userPath", 'User')
    if ($env:PATH -notlike "*$bin*") { $env:PATH = "$bin;$env:PATH" }
}

mutagen version
```

## 2. Daemon-Autostart (Scheduled Task, unsichtbar)

`mutagen daemon run` ist ein **Konsolen-Prozess im Vordergrund**. Direkt
als Scheduled-Task-Action mit `-LogonType Interactive` gestartet, oeffnet
Windows bei jedem Login ein sichtbares Konsolenfenster mit den
Daemon-Logs (scrollende `[sync]`/`[forward]`-Zeilen). Deshalb starten wir
den Daemon ueber einen **unsichtbaren VBS-Launcher**: `wscript.exe` ist
GUI-subsystem (selbst fensterlos) und startet `mutagen` mit Fensterstil
`0` = versteckt.

Supervision laeuft ueber denselben **2-Min-Watchdog** wie die beiden
Tunnel (`novnc-tunnel.md`): laeuft der Daemon schon, beendet sich ein
neuer `daemon run` sofort selbst (`daemon already running`); ist er tot,
kommt er binnen 2 Min wieder hoch. Das ersetzt die alleinige
RestartCount-Haertung und ist robuster gegen spaete Crashes.

> Hier ist der **Daemon-Lock** der Guard: `mutagen daemon run` bricht beim
> Doppelstart ab, *bevor* irgendeine SSH-Verbindung aufgebaut wird — daher
> ist der blinde 2-Min-Respawn hier leak-frei. Die Tunnel haben keinen
> solchen Lock und brauchen deshalb den expliziten Port-Listen-Check
> (`cockpit-scheduledtask.md`). Beide Muster NICHT vermischen.

```powershell
$bin = "$env:USERPROFILE\.local\bin"
$mutagenExe = "$bin\mutagen.exe"
$vbs = "$bin\mutagen-daemon-hidden.vbs"
$taskName = "mutagen-daemon"

# Unsichtbarer Launcher: startet `mutagen daemon run` mit Fensterstil 0.
# Der Exe-Pfad wird gequotet, weil Windows-Usernamen Leerzeichen enthalten
# koennen (z.B. C:\Users\Anna Beispiel\.local\bin\mutagen.exe).
$line = 'CreateObject("WScript.Shell").Run """{0}"" daemon run", 0, False' -f $mutagenExe
Set-Content -Path $vbs -Value $line -Encoding ASCII

# Action: wscript.exe (fensterlos) ruft den Launcher auf
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbs`""

# Trigger: bei Login + alle 2 Min Watchdog (identisch zu den Tunneln)
# -RepetitionDuration ist Pflicht: ohne sie bleibt die Duration leer und der Task
# feuert auf Win11 24H2 (Build 26100) nur EINMAL -> Watchdog tot.
# NICHT [TimeSpan]::MaxValue: der Task Scheduler lehnt das mit HRESULT 0x80041318
# (out of range) ab (real auf Win11 24H2, 2026-06-20). -Days 9999 (P9999D,
# ~27 Jahre) ist akzeptiert + effektiv unendlich, repetiert dauerhaft alle 2 Min.
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 2) `
    -RepetitionDuration (New-TimeSpan -Days 9999)).Repetition

# RestartInterval >= 1 Minute (PT30S ist ungueltig → HRESULT 0x80041318)
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

# Idempotent — vorher evtl. sichtbar gestarteten Daemon + alten Task entfernen
& $mutagenExe daemon stop 2>$null
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal | Out-Null

Start-ScheduledTask -TaskName $taskName
```

Kontrolle, dass kein Fenster mehr aufgeht und der Daemon trotzdem laeuft:

```powershell
Start-Sleep -Seconds 3
Get-Process mutagen -ErrorAction SilentlyContinue   # Daemon-Prozess laeuft (versteckt)
mutagen sync list ki-os                              # Session: "Watching for changes"
```

## 3. Session `ki-os` anlegen

Idempotenz-Check zuerst (`mutagen sync list ki-os` → existiert schon?).
Dann (`<VM_USER>` ersetzen):

```powershell
mutagen sync create `
    --name=ki-os `
    --sync-mode=two-way-resolved `
    --ignore-vcs `
    --ignore="node_modules" `
    --ignore=".venv" `
    --ignore="__pycache__" `
    --ignore=".obsidian/workspace*" `
    --ignore=".claude/skills" `
    --ignore=".cache" `
    --ignore="dist" `
    --ignore=".next" `
    --ignore=".DS_Store" `
    ki-os-vm:/home/<VM_USER>/KI-OS "$env:USERPROFILE\KI-OS"
```

VM ist **Alpha** (gewinnt bei Konflikten), lokal `%USERPROFILE%\KI-OS`
ist **Beta**. Begruendung der Ignores + Konflikt-Semantik:
`../macos/mutagen.md` (gilt 1:1 auch fuer Windows).

> **Windows-Unterschied — `.claude/skills` bleibt im Ignore.** Auf
> macOS/Linux wird die klickbare Skill-Ansicht (`.claude/skills` mit
> relativen In-Root-Symlinks) bewusst mitgesynct. Auf Windows brauchen
> Symlinks das Privileg `SeCreateSymbolicLinkPrivilege` (Developer-Mode
> oder Admin); ohne das wirft der Sync Fehler. Deshalb **bleibt
> `--ignore=".claude/skills"` auf Windows stehen** — der Rest synct
> fehlerfrei. Alternativ statt des Ignores `--symlink-mode=ignore` setzen,
> dann werden nur Symlinks (egal wo) uebersprungen und der Rest synct.
>
> **Caveat:** Die klickbare Skill-Ansicht ist auf Windows nicht
> verfuegbar. *Welche* Skills aktiv sind, siehst du ueber `.skill-profile`
> (wird gesynct) und die Cockpit Skill-Overview.
>
> **Opt-in fuer Fortgeschrittene:** Wer Windows-Developer-Mode aktiviert
> (Einstellungen → System → Fuer Entwickler → Entwicklermodus, gibt
> `SeCreateSymbolicLinkPrivilege`), kann `--ignore=".claude/skills"`
> weglassen und bekommt dieselbe klickbare Ansicht wie macOS/Linux. Ohne
> Developer-Mode nicht freigeben.

## 4. Verifikation

```powershell
mutagen sync list ki-os    # Status: "Watching for changes"
Get-ChildItem "$env:USERPROFILE\KI-OS"   # zeigt CLAUDE.md, hub/, ...
```

## Obsidian

Den Vault auf dem **lokalen** Ordner `%USERPROFILE%\KI-OS` oeffnen
(Obsidian → "Open folder as vault"). Gleiche UX wie frueher mit dem
sshfs-win-Laufwerk, aber: friert nicht ein, offline lesbar, schnelle
Suche.

## Troubleshooting

| Symptom | Loesung |
|---------|---------|
| `mutagen: command not found` | Neue PowerShell-Session oeffnen (PATH-Update) oder `$env:USERPROFILE\.local\bin\mutagen.exe` direkt aufrufen |
| "Connecting..." dauerhaft | SSH testen: `ssh -o BatchMode=yes ki-os-vm true` — Mutagen nutzt denselben Alias |
| Mutagen findet ssh nicht | OpenSSH-Client installieren (`ssh-setup.md`); `where.exe ssh` muss einen Treffer liefern |
| Daemon-Task beendet sich sofort | Erwartetes Verhalten des Watchdog-Musters: der VBS-Launcher feuert, `daemon run` sieht den schon laufenden Daemon und beendet sich (`daemon already running`) — der Daemon-Prozess selbst laeuft weiter. Mit `Get-Process mutagen` pruefen. |
| Daemon-Fenster geht beim Login trotzdem auf | Alter Task startet noch `mutagen.exe daemon run` direkt. Section 2 neu ausfuehren (registriert den Task auf den unsichtbaren VBS-Launcher um). |
| Sync laeuft nach Reboot nicht | Task-Status pruefen; `AtLogOn`-Trigger feuert nur bei echtem Windows-Login |
| "Conflicts" in `mutagen sync list` | `mutagen sync list ki-os --long`; VM-Version gewinnt — lokale Aenderung vorher wegsichern, falls gebraucht |
| Session kaputt/falsch konfiguriert | `mutagen sync terminate ki-os` + neu anlegen — Dateien bleiben erhalten |
