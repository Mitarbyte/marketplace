# =============================================================================
# setup-ssh.ps1 - SSH-Key + minimaler ssh-config-Eintrag (natives Windows)
#
# Erzeugt (falls noetig) den Ed25519-Key (leere Passphrase, 5.1/7-sicheres
# Quoting + Verifikation), ersetzt den Host-Block `ki-os-vm` idempotent
# (BOM-frei), repariert die ACLs und legt den Public Key in die Zwischenablage.
#
# PowerShell-5.1-kompatibel. Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File setup-ssh.ps1 `
#       -VmIp <IP> -VmUser <USER> [-Email <EMAIL>] [-NewKey]
#
# Output-Marker: KEY_EXISTS | KEY_CREATED, CONFIG_WRITTEN, PUBKEY: <key>
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$VmIp,
    [Parameter(Mandatory = $true)][string]$VmUser,
    [string]$Email = '',
    [switch]$NewKey
)
$ErrorActionPreference = 'Stop'

$sshDir = Join-Path $env:USERPROFILE '.ssh'
$key    = Join-Path $sshDir 'id_ed25519'
$cfg    = Join-Path $sshDir 'config'
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null

# --- SSH-Key -----------------------------------------------------------------
# Leere Passphrase VERSIONSSICHER: 5.1 (Legacy-Arg-Passing) braucht -N '""',
# PowerShell 7.2+ braucht -N ''. Falsch herum entsteht die 2-Zeichen-Passphrase
# """" -> "Permission denied (publickey)" im BatchMode trotz akzeptiertem Key.
$np = if ($PSVersionTable.PSVersion.Major -ge 7) { '' } else { '""' }

if ((Test-Path $key) -and (-not $NewKey)) {
    Write-Host "KEY_EXISTS: $key wird verwendet."
} else {
    if (Test-Path $key) {
        Write-Host "FAIL: $key existiert bereits - -NewKey wuerde ihn ueberschreiben. Erst manuell wegsichern/loeschen."
        exit 1
    }
    if ($Email) { ssh-keygen -t ed25519 -C $Email -f $key -N $np | Out-Null }
    else        { ssh-keygen -t ed25519 -f $key -N $np | Out-Null }
    Write-Host "KEY_CREATED: $key (Ed25519, ohne Passphrase)."
}

# Pflicht-Verifikation: Key MUSS ohne Passphrase nutzbar sein (faengt jede
# Fehl-Quoting-Variante sofort ab statt spaeter als raetselhaftes
# "Permission denied" beim Connect).
$null = ssh-keygen -y -P $np -f $key 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "FAIL: Der Key hat NICHT die erwartete leere Passphrase (Quoting-Problem)."
    Write-Host "  Key loeschen und Skript erneut laufen lassen:"
    Write-Host "  Remove-Item `"$key`", `"$key.pub`" -Force"
    Write-Host "  Danach den NEUEN Public Key an den Admin schicken - der alte ist ungueltig."
    exit 1
}

# --- Host-Block ersetzen (idempotent, BOM-frei) --------------------------------
# Bestehende ki-os-vm-Bloecke (inkl. Altlasten wie ki-os-vm-mux) entfernen,
# dann die minimale Fassung anhaengen. Bewusst KEIN ControlMaster, KEINE
# LocalForward-/RemoteForward-Zeilen - Tunnel laufen als Scheduled Tasks mit -L.
$kept = New-Object System.Collections.Generic.List[string]
if (Test-Path $cfg) {
    $skip = $false
    foreach ($line in (Get-Content -LiteralPath $cfg)) {
        if ($line -match '^\s*[Hh]ost\s+(\S+)') {
            $skip = @('ki-os-vm', 'ki-os-vm-mux') -contains $Matches[1]
        }
        if (-not $skip) { $kept.Add($line) }
    }
    while ($kept.Count -gt 0 -and $kept[$kept.Count - 1] -eq '') { $kept.RemoveAt($kept.Count - 1) }
}

$block = @"
Host ki-os-vm
    HostName $VmIp
    User $VmUser
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ServerAliveInterval 15
    ServerAliveCountMax 3
    ConnectTimeout 10
    TCPKeepAlive yes
"@

$body = if ($kept.Count -gt 0) { ($kept -join "`n") + "`n`n" + $block + "`n" } else { $block + "`n" }
$body = $body -replace "`r`n", "`n"

# BOM-frei schreiben (NICHT Add-Content -Encoding utf8: 5.1 schreibt ein BOM,
# an dem manche ssh-Builds abbrechen).
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($cfg, $body, $enc)
Write-Host "CONFIG_WRITTEN: Host ki-os-vm -> $VmUser@$VmIp ($cfg)"

# --- ACL-Reparatur (Windows-OpenSSH ist pingelig: "Bad owner or permissions") --
foreach ($f in @($key, $cfg)) {
    icacls $f /inheritance:r | Out-Null
    icacls $f /grant:r "$($env:USERNAME):(F)" | Out-Null
    icacls $f /remove "BUILTIN\Users" "Everyone" "NT AUTHORITY\Authenticated Users" 2>$null | Out-Null
}
Write-Host "OK: ACLs repariert (config + Private Key)."

# --- Public Key in die Zwischenablage + ausgeben --------------------------------
$pub = Get-Content -LiteralPath "$key.pub" -Raw
$pub = $pub.Trim()
try { Set-Clipboard -Value $pub; Write-Host "CLIPBOARD: Public Key kopiert (Set-Clipboard)." }
catch { $pub | clip.exe; Write-Host "CLIPBOARD: Public Key kopiert (clip.exe)." }
Write-Host "PUBKEY: $pub"
