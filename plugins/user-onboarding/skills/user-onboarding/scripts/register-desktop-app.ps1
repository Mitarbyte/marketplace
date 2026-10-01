# =============================================================================
# register-desktop-app.ps1 - Claude-Code-Desktop-App vorkonfigurieren (Windows)
#
# (a) SSH-Host ki-os-vm als gespeicherte Verbindung + Trusted-Host in
#     %APPDATA%\Claude\ssh_configs.json
# (b) Remote-Workspace ssh:ki-os-vm:/home/<VM_USER>/KI-OS als vertrautes
#     Projekt in ~\.claude.json (kein Trust-Prompt)
#
# PowerShell-5.1-kompatibel (kein -AsHashtable, kein Hashtable-Merge), alle
# JSON-Dateien BOM-frei geschrieben. Hintergrund + manueller Fallback:
# references/desktop-app.md.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File register-desktop-app.ps1 `
#       -VmUser <VM_USER>
# =============================================================================
param(
    [Parameter(Mandatory = $true)][string]$VmUser
)
$ErrorActionPreference = 'Stop'
$enc = New-Object System.Text.UTF8Encoding($false)

# --- (a) ssh_configs.json -------------------------------------------------------
$appdir = Join-Path $env:APPDATA 'Claude'
if (-not (Test-Path $appdir)) {
    Write-Host "SKIP: Claude-Desktop-App nicht gefunden ($appdir) - claude.ai/code oder Terminal nutzen."
} else {
    $cfgPath = Join-Path $appdir 'ssh_configs.json'
    if (-not (Test-Path $cfgPath)) {
        '{"configs":[],"trustedHosts":[]}' | Set-Content -LiteralPath $cfgPath -Encoding ascii
    }
    $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json
    if (-not ($cfg.PSObject.Properties.Name -contains 'configs') -or $null -eq $cfg.configs) {
        $cfg | Add-Member -NotePropertyName configs -NotePropertyValue @() -Force
    }
    if (-not ($cfg.PSObject.Properties.Name -contains 'trustedHosts') -or $null -eq $cfg.trustedHosts) {
        $cfg | Add-Member -NotePropertyName trustedHosts -NotePropertyValue @() -Force
    }
    if (-not (@($cfg.configs) | Where-Object { $_.sshHost -eq 'ki-os-vm' })) {
        $entry = [PSCustomObject]@{
            name    = 'ki-os-vm'
            sshHost = 'ki-os-vm'
            id      = [guid]::NewGuid().ToString()
            source  = 'desktop'
        }
        $cfg.configs = @($cfg.configs) + $entry
    }
    if (@($cfg.trustedHosts) -notcontains 'ki-os-vm') {
        $cfg.trustedHosts = @($cfg.trustedHosts) + 'ki-os-vm'
    }
    [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 100), $enc)
    Write-Host "OK: SSH-Host ki-os-vm in $cfgPath registriert."
    Write-Host 'HINWEIS: Desktop-App komplett beenden und neu oeffnen - sie liest ssh_configs.json nur beim Start.'
}

# --- (b) ~\.claude.json Workspace-Eintrag ----------------------------------------
$settings = Join-Path $env:USERPROFILE '.claude.json'
$key = "ssh:ki-os-vm:/home/$VmUser/KI-OS"

if (-not (Test-Path $settings)) {
    Write-Host "WARN: $settings fehlt - einmalig 'claude' lokal starten, dann diesen Schritt wiederholen (Skill-Re-Run ist idempotent)."
    exit 0
}

# Sicherheitsnetz: Backup vor dem Schreiben (einmal pro Lauf ueberschrieben)
Copy-Item $settings "$settings.bak-onboarding" -Force

$json = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
if ($null -eq $json) { Write-Host "FAIL: $settings liess sich nicht parsen - nicht ueberschrieben."; exit 1 }

if (-not ($json.PSObject.Properties.Name -contains 'projects') -or $null -eq $json.projects) {
    $json | Add-Member -NotePropertyName projects -NotePropertyValue ([PSCustomObject]@{}) -Force
}

$existing = $json.projects.PSObject.Properties[$key]
if ($existing) {
    # Bestehenden Eintrag nur ergaenzen - Trust-Flag setzen, Rest unangetastet
    if ($existing.Value.PSObject.Properties['hasTrustDialogAccepted']) {
        $existing.Value.hasTrustDialogAccepted = $true
    } else {
        $existing.Value | Add-Member -NotePropertyName hasTrustDialogAccepted -NotePropertyValue $true -Force
    }
} else {
    $entry = [PSCustomObject]@{
        allowedTools = @()
        mcpContextUris = @()
        enabledMcpjsonServers = @()
        disabledMcpjsonServers = @()
        hasTrustDialogAccepted = $true
        projectOnboardingSeenCount = 0
        hasClaudeMdExternalIncludesApproved = $false
        hasClaudeMdExternalIncludesWarningShown = $false
    }
    # Schluessel enthaelt ':' und '/' -> per Add-Member setzen, nicht Punkt-Notation
    $json.projects | Add-Member -NotePropertyName $key -NotePropertyValue $entry -Force
}

[System.IO.File]::WriteAllText($settings, ($json | ConvertTo-Json -Depth 100), $enc)
Write-Host "OK: $key in $settings registriert (hasTrustDialogAccepted=true)."
