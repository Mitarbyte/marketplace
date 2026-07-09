# =============================================================================
# check-prereqs.ps1 - Windows-Vorbedingungen in EINEM Durchlauf pruefen/installieren
#
#   1. Windows-OpenSSH-Client (Pflicht fuer SSH + Tunnel; Install braucht Admin)
#   2. Git for Windows (Pflicht - Claude Code braucht auf nativem Windows die
#      Git Bash; dessen ssh.exe wird NICHT verwendet)
#
# PowerShell-5.1-kompatibel. Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File check-prereqs.ps1
#
# Output-Marker: PREREQ ssh: OK|INSTALLED|MISSING_ADMIN  /  PREREQ git: OK|INSTALLED|FAILED
# =============================================================================
$ErrorActionPreference = 'Continue'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- 1. OpenSSH-Client -------------------------------------------------------
if (Get-Command ssh -ErrorAction SilentlyContinue) {
    Write-Host "PREREQ ssh: OK ($(ssh -V 2>&1))"
} elseif ($isAdmin) {
    try {
        Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0 | Out-Null
        Write-Host "PREREQ ssh: INSTALLED (OpenSSH.Client)"
    } catch {
        Write-Host "PREREQ ssh: MISSING_ADMIN - Installation fehlgeschlagen: $_"
    }
} else {
    Write-Host "PREREQ ssh: MISSING_ADMIN - als Administrator ausfuehren: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
}

# --- 2. Git for Windows ------------------------------------------------------
if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Host "PREREQ git: OK ($(git --version 2>&1))"
} else {
    try {
        winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
        Write-Host "PREREQ git: INSTALLED (neue PowerShell-Session noetig, damit git im PATH ist)"
    } catch {
        Write-Host "PREREQ git: FAILED - manuell installieren: winget install --id Git.Git -e"
    }
}

Write-Host "HINWEIS: Alle SSH-/Tunnel-Schritte nutzen den nativen Client C:\Windows\System32\OpenSSH\ssh.exe - die Git-Bash-ssh.exe NICHT vor ihn in den PATH stellen."
