# =============================================================================
# setup-mutagen.ps1 - Mutagen installieren + Daemon-Autostart + Session ki-os
# (natives Windows)
#
#   VM (Alpha, gewinnt Konflikte):  ki-os-vm:/home/<VM_USER>/KI-OS
#   Lokal (Beta):                   %USERPROFILE%\KI-OS
#
# Kein offizielles winget-Paket -> GitHub-Release-Zip nach ~\.local\bin
# (Download mit Retry). Der Daemon-Autostart laeuft NICHT ueber einen eigenen
# Task, sondern ueber den gemeinsamen Watchdog-Task ki-os-vm-watchdog; fehlt
# der noch, legt dieses Skript ihn selbst an (setup-tunnels.ps1 -EnsureMutagen,
# additiv/Mutagen-only) - das Setup ist damit selbsttragend, keine
# Reihenfolge-Abhaengigkeit zu Schritt 7. `.claude/skills` bleibt auf Windows
# im Ignore (Symlinks brauchen SeCreateSymbolicLinkPrivilege).
# Details: references/mutagen.md.
#
# Symlinks werden auf Windows komplett uebersprungen (--symlink-mode=ignore).
# Teilt der User seinen `Workspaces`-Ordner per Bind-Mount mit Kollegen, bekommt
# alles, was Mutagen VM-seitig anlegt, dessen Gruppe + group-schreibbare Modes.
# Das wird VM-seitig ERKANNT (setgid-Bit), nicht angenommen.
#
# PowerShell-5.1-kompatibel. Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File setup-mutagen.ps1 `
#       [-VmUser <VM_USER>] [-Recreate] [-SharedGroup <NAME>|'']
#
# -VmUser ist optional: das Skript erkennt den VM-User per SSH selbst (im
# selben Roundtrip wie die Shared-Group). Angeben nur, wenn SSH gerade nicht
# erreichbar ist UND die Session neu angelegt werden muss.
#
# Output-Marker: SESSION_EXISTS | SESSION_CREATED | SESSION_RECREATED
# =============================================================================
param(
    [string]$VmUser = '',
    [switch]$Recreate,
    # Shared-Group fuer einen geteilten `Workspaces`-Bind-Mount. NICHT angeben =
    # VM-seitig erkennen (setgid-Bit); explizit angeben ueberstimmt die
    # Erkennung, '' erzwingt aus.
    # Begruendung: references/mutagen.md -> "Shared-Group".
    [string]$SharedGroup,
    # Deprecated seit 2026-08-13, wird ignoriert: der Daemon-Autostart laeuft
    # jetzt in JEDEM Modus additiv ueber setup-tunnels.ps1 -EnsureMutagen
    # (nicht-destruktiv, laesst Alt-Tunnel-Tasks stehen) - eine gateway-
    # Sonderbehandlung ist damit ueberfluessig. Akzeptiert bleibt der Switch,
    # damit bestehende Anleitungen/SKILL-Staende nicht brechen.
    [switch]$Gateway
)
$ErrorActionPreference = 'Stop'

# --- Native Kommandos mit ERWARTETEM stderr sicher aufrufen ---------------------
# PowerShell 5.1 macht unter $ErrorActionPreference='Stop' aus JEDER stderr-Zeile
# eines nativen Kommandos einen terminierenden NativeCommandError - auch dann,
# wenn stderr per `2>$null` umgeleitet ist und der Fall voellig normal ist.
# Beobachtet bei Jobst/heimatwerft 2026-08-04: `find ... /KI-OS/Workspaces` meldet
# "No such file or directory" (= Normalfall: kein geteilter Bind-Mount) und das
# GESAMTE Setup brach in Schritt 0b ab, bevor Mutagen ueberhaupt installiert war.
# Dieselbe Falle: `mutagen daemon stop` ohne laufenden Daemon und
# `mutagen sync list ki-os` ohne existierende Session (= jeder Erstlauf!).
# Darum diese Aufrufe hier kapseln: Preference nur fuer den nativen Call senken,
# danach zuverlaessig zuruecksetzen. $LASTEXITCODE bleibt dabei auswertbar.
function Invoke-NativeQuiet {
    param([Parameter(Mandatory = $true)][scriptblock]$Command)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command } finally { $ErrorActionPreference = $prevEap }
}

$binDir     = Join-Path $env:USERPROFILE '.local\bin'
$mutagenExe = Join-Path $binDir 'mutagen.exe'
New-Item -ItemType Directory -Path $binDir -Force | Out-Null

# --- 0. Transport auf Windows-OpenSSH festnageln --------------------------------
# Mutagen sucht sich sein ssh SELBST und bevorzugt auf Windows die
# Git-for-Windows-MSYS2-ssh (C:\Program Files\Git\usr\bin\ssh.exe) - auch dann,
# wenn die NICHT im PATH steht und System32\OpenSSH davor liegt. Deren
# Pipe-Emulation kann den Agent-Transport haengen lassen: der mutagen-agent auf
# der VM stirbt, lokal bleibt die Session in "Applying changes" stehen und
# `sync pause` antwortet nicht mehr (Daemon-Goroutine blockiert). MUTAGEN_SSH_PATH
# stellt den Suchpfad voran -> nativer Windows-OpenSSH, wie im Skill vorgesehen.
# Persistent (User-Scope) setzen, damit der vom Watchdog-Task gestartete Daemon
# ihn ebenfalls erbt.
$opensshDir = 'C:\Windows\System32\OpenSSH'
if (Test-Path (Join-Path $opensshDir 'ssh.exe')) {
    [Environment]::SetEnvironmentVariable('MUTAGEN_SSH_PATH', $opensshDir, 'User')
    $env:MUTAGEN_SSH_PATH = $opensshDir
    Write-Host "OK: MUTAGEN_SSH_PATH=$opensshDir (erzwingt Windows-OpenSSH statt Git-Bash-ssh)"
} else {
    Write-Host "WARN: $opensshDir\ssh.exe fehlt - check-prereqs.ps1 laufen lassen."
}

# --- 0b. VM-User + Shared-Group in EINEM SSH-Roundtrip erkennen ------------------
# VM-User: fuer den Default-Alpha-Endpunkt bei Neuanlage (bei bestehender
# Session unnoetig - deshalb ist das Fehlen erst im Create-Pfad ein Fehler).
# Shared-Group: ein geteilter `Workspaces`-Bind-Mount ist auf der VM als
# setgid-Verzeichnis (drwxrws---, Modus 2770) mit der geteilten Gruppe
# angelegt - genau daran ist er erkennbar. Deshalb wird NICHTS angenommen:
# kein geteilter Ordner -> keine Gruppen-Freigabe (Normalfall). Grund fuer die
# explizite Gruppe (Mutagen staged ausserhalb des Roots und renamed hinein,
# setgid vererbt dabei nicht): references/mutagen.md.
# Das Remote-Kommando steht bewusst ohne Quotes/Redirects da: als EIN
# single-quoted Argument uebergeben interpretiert PowerShell weder $HOME noch
# ein 2> - und es ist identisch zur sh-Variante.
# ssh-Exit-Codes: 255 = Transportfehler (dann laut warnen statt still "aus"
# annehmen); alles andere (auch 1 = Workspaces-Ordner fehlt) ist auswertbar -
# Zeile 1 ist der VM-User, Zeile 2 (falls vorhanden) die setgid-Gruppe.
$needUser  = -not $VmUser
$needGroup = -not $PSBoundParameters.ContainsKey('SharedGroup')
if ($needGroup) { $SharedGroup = '' }
if ($needUser -or $needGroup) {
    $remoteCmd = 'id -un && find $HOME/KI-OS/Workspaces -maxdepth 0 -perm -2000 -printf %g'
    $remoteOut = @(Invoke-NativeQuiet { & ssh -o BatchMode=yes -o ConnectTimeout=10 ki-os-vm $remoteCmd 2>$null } | ForEach-Object { "$_".Trim() })
    if ($LASTEXITCODE -eq 255) {
        Write-Host 'WARN: VM-Erkennung fehlgeschlagen (SSH nicht erreichbar).'
        Write-Host '      Es wird KEINE Gruppen-Freigabe gesetzt. Teilst du deinen'
        Write-Host '      Workspaces-Ordner mit Kollegen, den Schritt mit'
        Write-Host '      -SharedGroup <NAME> wiederholen.'
    } else {
        if ($needUser -and $remoteOut.Count -ge 1 -and $remoteOut[0]) {
            $VmUser = $remoteOut[0]
            Write-Host "OK: VM-User '$VmUser' erkannt."
        }
        if ($needGroup -and $remoteOut.Count -ge 2 -and $remoteOut[1]) {
            $SharedGroup = $remoteOut[1]
            Write-Host "OK: geteilter Workspaces-Ordner erkannt - Shared-Group '$SharedGroup'."
        }
    }
}

# --- 1. Installieren (mit Retry) -----------------------------------------------
$mutagenCmd = Get-Command mutagen -ErrorAction SilentlyContinue
if ($mutagenCmd) { $mutagenExe = $mutagenCmd.Source }

if (-not (Test-Path $mutagenExe)) {
    $ok = $false
    for ($i = 1; $i -le 3 -and -not $ok; $i++) {
        try {
            $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/mutagen-io/mutagen/releases/latest' -TimeoutSec 30
            $url = ($rel.assets | Where-Object { $_.name -match 'windows_amd64.*\.zip$' -and $_.name -notmatch 'sidecar' })[0].browser_download_url
            $zip = Join-Path $env:TEMP 'mutagen.zip'
            # Invoke-WebRequest zeichnet ohne diese Zeile pro Chunk eine
            # Fortschrittsanzeige - in einer NICHT-interaktiven Session (genau so
            # laeuft das Skill) kostet dieses Rendering ein Vielfaches des
            # Downloads: >10 min statt ~4 s, was wie ein Haenger aussieht.
            # Beobachtet bei Marc/heimatwerft 2026-08-07.
            $prevProgress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try {
                Invoke-WebRequest -Uri $url -OutFile $zip -TimeoutSec 300
            } finally {
                $ProgressPreference = $prevProgress
            }
            Expand-Archive -Path $zip -DestinationPath $binDir -Force
            Remove-Item $zip -ErrorAction SilentlyContinue
            $ok = $true
        } catch {
            Write-Host "WARN: Download-Versuch $i/3 fehlgeschlagen: $($_.Exception.Message)"
            Start-Sleep -Seconds (5 * $i)
        }
    }
    if (-not $ok) { Write-Host 'FAIL: Mutagen-Download nach 3 Versuchen fehlgeschlagen - Netz pruefen, Schritt wiederholen.'; exit 1 }

    # PATH erweitern (User-Scope), falls noetig
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($userPath -notlike "*$binDir*") {
        [Environment]::SetEnvironmentVariable('PATH', "$binDir;$userPath", 'User')
    }
    if ($env:PATH -notlike "*$binDir*") { $env:PATH = "$binDir;$env:PATH" }
}
# In Invoke-NativeQuiet: schreibt das Binary auch nur eine Zeile auf stderr
# (z.B. Daemon-Versions-Hinweis), macht PS 5.1 unter Stop + Redirect daraus
# sonst einen terminierenden NativeCommandError.
$mutagenVersion = (Invoke-NativeQuiet { & $mutagenExe version 2>&1 } | Out-String).Trim()
Write-Host "OK: mutagen $mutagenVersion ($mutagenExe)"

# --- 2. Daemon-Autostart (Watchdog-Task, selbsttragend) --------------------------
# Den Autostart faehrt der gemeinsame Scheduled Task ki-os-vm-watchdog: sein
# 2-Min-Guard startet den Daemon unsichtbar, sobald mutagen installiert ist und
# kein Daemon laeuft (Daemon-Lock als Backstop). Existiert der Task noch nicht
# (Tunnel-Setup nicht gelaufen, gateway-VM, Mutagen-only-Nutzung), legt
# setup-tunnels.ps1 -EnsureMutagen ihn ADDITIV Mutagen-only an - ohne Cleanup,
# also ohne Risiko fuer funktionierende Alt-Tunnel; ein spaeterer voller
# Schritt-7-Lauf erweitert denselben Task um die Tunnel. Damit gibt es KEINE
# Reihenfolge-Abhaengigkeit Schritt 7 -> 8 mehr.
# Hier zusaetzlich: evtl. sichtbar gestarteten Daemon abloesen, den frueheren
# Einzel-Task mutagen-daemon aufraeumen.
$watchdog = 'ki-os-vm-watchdog'
Invoke-NativeQuiet { & $mutagenExe daemon stop 2>$null } | Out-Null
Unregister-ScheduledTask -TaskName 'mutagen-daemon' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item (Join-Path $binDir 'mutagen-daemon-hidden.vbs') -ErrorAction SilentlyContinue
if (Get-ScheduledTask -TaskName $watchdog -ErrorAction SilentlyContinue) {
    Start-ScheduledTask -TaskName $watchdog
    Start-Sleep -Seconds 5
    Write-Host "OK: Daemon-Autostart via Scheduled Task $watchdog"
} else {
    $setupTunnels = Join-Path $PSScriptRoot 'setup-tunnels.ps1'
    $ensured = $false
    if (Test-Path $setupTunnels) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupTunnels -EnsureMutagen
        if ($LASTEXITCODE -eq 0) {
            $ensured = $true
            Start-Sleep -Seconds 5
            Write-Host "OK: Daemon-Autostart via Scheduled Task $watchdog (Mutagen-only angelegt)"
            Write-Host "    Hinweis: Tunnel sind damit NICHT eingerichtet - auf tunnel-VMs bei"
            Write-Host "    Bedarf setup-tunnels.ps1 mit Ports laufen lassen (Schritt 7)."
        } else {
            # Kind-Skript scheiterte (native Exit-Codes werfen unter Stop nicht).
            Write-Host "WARN: setup-tunnels.ps1 -EnsureMutagen scheiterte (Exit $LASTEXITCODE)."
        }
    } else {
        Write-Host "WARN: setup-tunnels.ps1 fehlt neben setup-mutagen.ps1 (Skill unvollstaendig installiert?)."
    }
    if (-not $ensured) {
        # Daemon wenigstens fuer diese Session direkt starten statt falsches OK;
        # nach Reboot muss der Schritt dann wiederholt werden.
        Write-Host 'WARN: kein Daemon-Autostart eingerichtet - Daemon nur fuer diese Session direkt starten.'
        Start-Process -WindowStyle Hidden -FilePath $mutagenExe -ArgumentList 'daemon', 'run'
        Start-Sleep -Seconds 3
    }
}

# --- 3. Session ki-os -------------------------------------------------------------
function New-KiOsSession {
    # Endpunkte: $Alpha/$Beta ueberschreiben die Konvention. Fuer -Recreate ist das
    # PFLICHT, nicht Komfort - ein Bestands-Setup kann einen anderen SSH-Alias und
    # einen anderen lokalen Ordner haben. Wuerde die Neuanlage stur die Konvention
    # nehmen, terminiert sie die funktionierende Session und legt eine neue auf
    # einen fremden Alias + fast leeren Ordner an.
    param(
        [string]$Alpha = "ki-os-vm:/home/$VmUser/KI-OS",
        [string]$Beta  = "$env:USERPROFILE\KI-OS"
    )
    # VM ist Alpha (gewinnt bei Konflikten), lokal ist Beta.
    $sshArgs = @(
        'sync', 'create',
        '--name=ki-os',
        '--sync-mode=two-way-resolved',
        # Symlinks auf Windows GAR NICHT anfassen. Der Ignore `.claude/skills`
        # allein reicht nicht: der Workspace hat zusaetzlich ~54 relative
        # Symlinks unter `hub/Skills/*/*/scripts/` (-> ../../../../lib/*.py).
        # Ohne SeCreateSymbolicLinkPrivilege (Developer Mode) scheitert jeder
        # davon als "Transition problem"; die Session retryt sie endlos und
        # erreicht nie "Watching for changes" - fuer den User sieht das aus wie
        # "der Sync bleibt dauernd stehen". Mit `ignore` werden sie uebersprungen;
        # die Zieldateien liegen ueber `hub/lib/` lokal ohnehin vor.
        # Opt-in fuer die klickbare Skill-Ansicht: Developer Mode an, dann ohne
        # dieses Flag + ohne den .claude/skills-Ignore neu anlegen.
        '--symlink-mode=ignore',
        '--ignore-vcs',
        '--ignore=node_modules',
        '--ignore=.venv',
        '--ignore=__pycache__',
        '--ignore=.obsidian/workspace*',
        # Cloud-Sync-Ordner (root-verankert, fuehrender Slash): gehoeren dem
        # VM-seitigen Cloud-Sync und duerfen NICHT zusaetzlich durch Mutagen
        # laufen — sonst haengen an denselben Bytes drei Sync-Engines mit zwei
        # unabhaengigen Konfliktmodellen (Mutagen VM<->Client, Cloud-Client
        # VM<->Cloud, Cloud-Client der Kollegen an derselben Bibliothek). Der
        # Ordner liegt ueber die Cloud ohnehin schon auf jedem Windows-
        # Arbeitsplatz — hier waere er die zweite, konkurrierende Kopie
        # desselben Baums.
        #
        # Literale (Ordnername hat Historie, ist fleet-weite Konvention):
        #   /Ablage       — aktuelle Konvention, providerneutral
        #   /SharePoint   — Bestand (schleumer, bleibt bewusst dort)
        #   /Sharepoint   — dieselbe Schreibweise mit kleinem p, real vergeben
        #   /Google Drive — Name, den Google Drive for Desktop selbst vergibt
        #   /Geteilte-Arbeitsplaetze, /Meine-Arbeitsplaetze, /dev — Drei-Ordner-
        #                   Struktur des cloud-Hub-Backends (plus Firmenordner
        #                   via $env:COMPANY_LOCAL, s.u.)
        # Mutagen-Ignores sind CASE-SENSITIV: '/SharePoint' trifft einen Ordner
        # 'Sharepoint' nicht (aufgefallen 2026-08-12 - der lief unbemerkt doppelt).
        # Jedes ist ein No-op, solange der Ordner nicht existiert.
        '--ignore=/Ablage',
        '--ignore=/SharePoint',
        '--ignore=/Sharepoint',
        '--ignore=/Google Drive',
        '--ignore=/Geteilte-Arbeitsplaetze',
        '--ignore=/Meine-Arbeitsplaetze',
        '--ignore=/dev',
        '--ignore=.claude/skills',
        '--ignore=.cache',
        '--ignore=dist',
        '--ignore=.next',
        '--ignore=.DS_Store'
    )
    # Firmenordner des cloud-Backends (Name aus get-vm-values: COMPANY_LOCAL) —
    # pro Kunde verschieden, daher per Env statt Literal.
    if ($env:COMPANY_LOCAL) {
        $sshArgs += "--ignore=/$($env:COMPANY_LOCAL)"
    }
    # Shared-Group fuer den geteilten Bind-Mount `Workspaces`: Dateien, die
    # Mutagen VM-seitig anlegt, muessen fuer die anderen Mitarbeiter der Gruppe
    # les-/schreibbar sein - sonst laufen deren Agents in Permission-Fehler.
    # Nur alpha (VM); auf Windows-Beta sind POSIX-Modes bedeutungslos.
    if ($SharedGroup) {
        $sshArgs += "--default-group-alpha=$SharedGroup"
        $sshArgs += '--default-file-mode-alpha=0660'
        $sshArgs += '--default-directory-mode-alpha=0770'
    }
    $sshArgs += $Alpha
    $sshArgs += $Beta
    & $mutagenExe @sshArgs
}

# Endpunkt einer bestehenden Session auslesen ('Alpha' oder 'Beta').
function Get-KiOsEndpoint([string]$Section) {
    $long = (Invoke-NativeQuiet { & $mutagenExe sync list ki-os --long 2>&1 }) | Out-String
    $m = [regex]::Match($long, "(?ms)^${Section}:\r?\n.*?^\s+URL:\s*(.+?)\r?$")
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

Invoke-NativeQuiet { & $mutagenExe sync list ki-os 2>$null } | Out-Null
if ($LASTEXITCODE -eq 0) {
    if ($Recreate) {
        # Endpunkte VOR dem terminate sichern - danach sind sie nicht mehr lesbar.
        $oldAlpha = Get-KiOsEndpoint 'Alpha'
        $oldBeta  = Get-KiOsEndpoint 'Beta'
        if (-not $oldAlpha -or -not $oldBeta) {
            Write-Error 'FAIL: Endpunkte der bestehenden Session nicht lesbar - es wird NICHTS terminiert. Sonst entstuende eine Neuanlage auf geratenen Endpunkten. Pruefen: mutagen sync list ki-os --long'
            exit 1
        }
        if ($oldAlpha -ne "ki-os-vm:/home/$VmUser/KI-OS" -or $oldBeta -ne "$env:USERPROFILE\KI-OS") {
            Write-Host 'OK: Endpunkte der bestehenden Session werden uebernommen (Bestands-Setup):'
            Write-Host "    alpha: $oldAlpha"
            Write-Host "    beta:  $oldBeta"
        }
        & $mutagenExe sync terminate ki-os
        New-KiOsSession -Alpha $oldAlpha -Beta $oldBeta
        Write-Host "SESSION_RECREATED: ki-os neu angelegt ($oldAlpha <-> $oldBeta; Dateien bleiben erhalten)."
    } else {
        Write-Host 'SESSION_EXISTS: ki-os laeuft bereits.'
        # Konfig-Drift AKTIV melden: Ignores/Symlink-Mode/Group einer bestehenden
        # Session sind unveraenderlich, ein blosser Re-Run heilt sie NICHT. Bleibt
        # das unbemerkt, retryt die Session z.B. die 137 Skill-Symlinks endlos und
        # steht dauerhaft auf "Applying changes" statt "Watching for changes".
        $cfg = (Invoke-NativeQuiet { & $mutagenExe sync list ki-os --long 2>&1 }) | Out-String
        $drift = @()
        if ($cfg -notmatch 'Symbolic link mode:\s*Ignore')      { $drift += '--symlink-mode=ignore fehlt (Skill-Symlinks scheitern als Transition problems)' }
        if ($cfg -notmatch '(?m)^\s+\.claude/skills\s*$')       { $drift += 'Ignore .claude/skills fehlt' }
        # Jedes fehlende Cloud-Sync-Literal einzeln melden: Sessions von vor der
        # Umbenennung auf 'Ablage' kennen nur '/SharePoint'. Echter Ausfall ist
        # das erst, wenn der jeweilige Ordner auf der VM benutzt wird.
        $ignExpected = @('/Ablage', '/SharePoint', '/Sharepoint', '/Google Drive',
                         '/Geteilte-Arbeitsplaetze', '/Meine-Arbeitsplaetze', '/dev')
        if ($env:COMPANY_LOCAL) { $ignExpected += "/$($env:COMPANY_LOCAL)" }
        foreach ($ign in $ignExpected) {
            if ($cfg -notmatch "(?m)^\s+$([regex]::Escape($ign))\s*$") {
                $drift += "Ignore $ign fehlt (Cloud-Sync-Ordner wuerde doppelt gesynct, falls auf dieser VM genutzt)"
            }
        }
        if ($SharedGroup -and ($cfg -notmatch "Default file/directory group:\s*$([regex]::Escape($SharedGroup))")) {
            $drift += "Shared-Group '$SharedGroup' auf alpha fehlt (geteilter Workspaces-Bind-Mount)"
        }
        if ($drift.Count -gt 0) {
            Write-Host 'DRIFT: die bestehende Session weicht vom Template ab:'
            $drift | ForEach-Object { Write-Host "  - $_" }
            Write-Host '  -> einmalig mit -Recreate neu anlegen (Dateien bleiben erhalten).'
            Write-Host '  -> VORHER pruefen, dass beide Seiten konvergiert sind (`mutagen sync list ki-os`:'
            Write-Host '     gleiche Datei-/Verzeichniszahl auf alpha und beta) - sonst spuelt der frische'
            Write-Host '     Ancestor lokal-only Daten als Neuanlage auf die VM.'
            # Der dokumentierte Developer-Mode-Opt-in legt die Session BEWUSST ohne
            # symlink-mode=ignore + ohne den .claude/skills-Ignore an (klickbare
            # Skill-Ansicht). Ohne diesen Hinweis meldet das Skript ihm bei jedem
            # Lauf "Drift" und schickt ihn in eine unnoetige Neuanlage.
            if ($drift -match 'symlink|\.claude/skills') {
                Write-Host '  -> Hinweis: Wenn du den Windows-Developer-Mode bewusst nutzt (klickbare'
                Write-Host '     Skill-Ansicht, references/mutagen.md), sind die Symlink-Zeilen erwartet'
                Write-Host '     und kein Fehler - dann hier nichts tun.'
            }
        } else {
            Write-Host 'OK: Session-Konfiguration entspricht dem Template.'
        }
    }
} else {
    # Nur die NEUANLAGE braucht den VM-User (Default-Alpha-Endpunkt) - erst
    # hier ist sein Fehlen ein Fehler, nicht schon beim Start.
    if (-not $VmUser) {
        Write-Host 'FAIL: VM-User unbekannt - SSH-Erkennung fehlgeschlagen und -VmUser nicht'
        Write-Host '      angegeben. Neuanlage braucht den VM-Pfad: erst SSH fixen'
        Write-Host '      (ssh ki-os-vm) oder -VmUser <NAME> mitgeben.'
        exit 1
    }
    New-KiOsSession
    Write-Host "SESSION_CREATED: ki-os (VM:/home/$VmUser/KI-OS <-> $env:USERPROFILE\KI-OS)"
}

# --- 4. Aufloeser fuer blockierte VM-Loeschungen --------------------------------
# Raeumt ein Agent auf der VM einen Ordner weg, loescht Mutagen ihn lokal NICHT,
# solange darin ignorierte Dateien liegen (node_modules, __pycache__, .DS_Store -
# letztere landen ueber den Sync auch auf Windows-Seiten). Es entsteht ein
# Konflikt "(alpha) X (Directory -> <non-existent>)" + "(beta) X/y/... (
# <non-existent> -> Untracked content)" und der Ordner bleibt lokal KOMPLETT
# stehen, inkl. aller getrackten Dateien. Eine einzige ignorierte Datei tief im
# Baum reicht. Ohne Eingriff divergieren beide Seiten dauerhaft still.
# Der Aufloeser raeumt genau die benannten Reste weg (verschieben, nicht loeschen)
# -> danach fuehrt Mutagen die Loeschung selbst aus. Aufgerufen wird er vom
# 2-Min-Watchdog (ki-os-vm-watchdog aus setup-tunnels.ps1).
# Begruendung + Grenzen: references/mutagen.md -> "Blockierte VM-Loeschungen".
$resolver = Join-Path $binDir 'ki-os-sync-resolve.ps1'
@'
# ki-os-sync-resolve.ps1 - generiert von setup-mutagen.ps1.
# Loest Mutagen-Konflikte auf, bei denen eine VM-seitige Loeschung lokal an
# ignorierten Resten haengt. Details: user-onboarding/references/mutagen.md.
$ErrorActionPreference = 'SilentlyContinue'
$mutagen = Join-Path $env:USERPROFILE '.local\bin\mutagen.exe'
if (-not (Test-Path $mutagen)) { $mutagen = (Get-Command mutagen).Source }
if (-not $mutagen) { return }

$conf = & $mutagen sync list ki-os --long 2>$null | Out-String
$m = [regex]::Match($conf, '(?ms)^Conflicts:\r?\n(.*?)^Status:')
if (-not $m.Success) { return }

# Nur Wegwerf-Artefakte. .git fehlt hier ABSICHTLICH: ein lokaler Repo-Klon ist
# eine bewusste Entscheidung des Users, die kein Automatismus wegraeumt.
$disposable = @('.DS_Store', 'Thumbs.db', 'node_modules', '__pycache__', '.venv', '.cache', 'dist', '.next')
function Test-Disposable([string]$p) {
    foreach ($seg in ($p -split '[/\\]')) { if ($disposable -contains $seg) { return $true } }
    return $false
}

# Lokalen Sync-Ordner AUS DER SESSION lesen, nicht %USERPROFILE%\KI-OS annehmen:
# der Skill legt ihn zwar dort an, Bestands-Setups haben ihn aber woanders. Mit
# falscher Wurzel findet der Aufloeser nichts und tut still nichts - der Bug
# faellt nicht auf, weil er wie "nichts zu tun" aussieht.
$root = Join-Path $env:USERPROFILE 'KI-OS'
$betaUrl = [regex]::Match($conf, '(?ms)^Beta:\r?\n.*?^\s+URL:\s*(.+?)\r?$')
if ($betaUrl.Success) {
    $cand = $betaUrl.Groups[1].Value.Trim()
    if ($cand -and (Test-Path -LiteralPath $cand)) { $root = $cand }
}
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$stateDir  = Join-Path $env:USERPROFILE '.local\state\ki-os'
$trashRoot = Join-Path $stateDir 'sync-trash'
$trash = Join-Path $trashRoot $stamp
$did = $false

# Auffaelligkeiten sammeln und erst am Ende melden - und dort nur, wenn sie sich
# seit dem letzten Lauf GEAENDERT haben. Der Aufloeser laeuft alle 2 min; ein
# Dauerproblem wuerde das Log sonst mit derselben Meldung fluten und dabei genau
# das verdecken, was neu ist.
$issues = @()
$issuesLast = Join-Path $stateDir 'watchdog-issues.last'

# Blockweise auswerten, damit ein .git in Block A nicht die Aufloesung von
# Block B verhindert - und kein Block halb aufgeloest wird.
foreach ($block in ($m.Groups[1].Value -split '\r?\n\s*\r?\n')) {
    # Welchen Ordner hat alpha geloescht? (Nur Directory-Faelle: bei Dateien gibt
    # es das Untracked-Problem nicht.)
    $t = [regex]::Match($block, '(?m)^\s*\(alpha\)\s+(.*) \(Directory -> <non-existent>\)\s*$')
    if (-not $t.Success) { continue }
    $target = $t.Groups[1].Value
    $betas = @([regex]::Matches($block, '(?m)^\s*\(beta\)\s+(.*) \(<non-existent> -> Untracked content\)\s*$') |
              ForEach-Object { $_.Groups[1].Value })
    if ($betas.Count -eq 0) { continue }
    $bad = @($betas | Where-Object { -not (Test-Disposable $_) })
    if ($bad.Count -gt 0) {
        $bad | ForEach-Object { $issues += "SYNC-BLOCK: '$_' ist kein Wegwerf-Artefakt (z.B. .git) - bitte lokal selbst entscheiden." }
        continue
    }
    # Den Ordner KOMPLETT sichern, nicht nur die Reste: sonst loescht Mutagen den
    # Rest selbst und nimmt dabei auch Dateien mit, die es nur lokal gibt.
    $src = Join-Path $root ($target -replace '/', '\')
    if (-not (Test-Path -LiteralPath $src)) { continue }
    $dst = Join-Path $trash ($target -replace '/', '\')
    New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
    # Move-Fehler NICHT verschlucken: solange er still war, sah ein dauerhaft
    # blockierter Aufloeser wie "nichts zu tun" aus (leeres Log) und hinterliess
    # bei jedem Lauf nur den leeren Zielordner von New-Item (auf macOS real
    # aufgetreten: 3708 leere Ordner in 8 Tagen, s. references/mutagen.md).
    $moveErr = $null
    try   { Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop }
    catch { $moveErr = $_.Exception.Message }
    if (-not $moveErr -and -not (Test-Path -LiteralPath $src)) {
        Write-Output "SYNC-FIX: '$target' war auf der VM geloescht und lokal durch ignorierte Reste blockiert"
        Write-Output "          -> komplett gesichert nach $dst"
        Write-Output "          -> Sync ist jetzt konsistent. Papierkorb pruefen und bei Bedarf leeren."
        $did = $true
    } else {
        $issues += "SYNC-FAIL: '$target' konnte nicht in den Papierkorb verschoben werden."
        if ($moveErr) { $issues += "           $moveErr" }
        $issues += "           -> Haeufigste Ursache auf Windows: eine Datei im Ordner ist von"
        $issues += "              einem Prozess gesperrt (Editor, Explorer-Vorschau, Virenscanner)."
    }
}
# Flush anstossen, damit die nun unblockierte Loeschung sofort laeuft.
if ($did) { & $mutagen sync flush ki-os 2>$null | Out-Null }

# --- Leere Papierkorb-Ordner aufraeumen ---------------------------------------
# Scheitert das Move, bleibt der per New-Item vorbereitete Zielpfad leer zurueck.
# Nur VOLLSTAENDIG leere Verzeichnisse werden entfernt, echte Sicherungen bleiben.
# Mehrere Durchlaeufe, weil ein Parent erst dann leer ist, wenn seine Kinder im
# vorherigen Durchlauf verschwunden sind.
if (Test-Path -LiteralPath $trashRoot) {
    for ($i = 0; $i -lt 8; $i++) {
        $empty = @(Get-ChildItem -LiteralPath $trashRoot -Directory -Recurse -Force -ErrorAction SilentlyContinue |
                   Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) })
        if ($empty.Count -eq 0) { break }
        $empty | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    }
}

# --- Auffaelligkeiten melden (nur bei Aenderung, s. oben) ---------------------
if ($issues.Count -gt 0) {
    $text = ($issues -join "`n")
    $prev = ''
    if (Test-Path -LiteralPath $issuesLast) { $prev = (Get-Content -LiteralPath $issuesLast -Raw -ErrorAction SilentlyContinue) }
    if ($text -ne $prev) {
        $issues | ForEach-Object { Write-Output $_ }
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        Set-Content -LiteralPath $issuesLast -Value $text -Encoding ASCII
    }
} elseif (Test-Path -LiteralPath $issuesLast) {
    # Problem weg -> Merkdatei zuruecksetzen, damit ein spaeteres Wiederauftreten
    # erneut gemeldet wird.
    Remove-Item -LiteralPath $issuesLast -Force -ErrorAction SilentlyContinue
}
'@ | Set-Content -Path $resolver -Encoding ASCII
Write-Host "OK: Sync-Aufloeser ($resolver) - laeuft im 2-Min-Watchdog"

& $mutagenExe sync list ki-os
