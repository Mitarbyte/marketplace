# =============================================================================
# get-vm-values.ps1 - Smoketest + pro-User-Werte in EINEM SSH-Roundtrip (Windows)
#
# Holt Engine, Zustand des Display-Stacks und die Gateway-URLs des Users von
# der VM. Schlaegt die Verbindung fehl, wird der SSH-Fehler ausgegeben
# (Diagnose: references/ssh.md).
#
# PowerShell-5.1-kompatibel. Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File get-vm-values.ps1
# Nicht auf Pfad H (gateway auf reiner Hermes-VM, ADR 22 Nr. 10): dort gibt es
# keinen SSH-Zugang vom Geraet - die URLs kommen aus `ki-os-fleet vm zugang`.
#
# Output-Marker: SSH_OK | SSH_FAIL,
#                ENGINE= (claude|hybrid|hermes - auf hermes gibt es KEIN Cockpit;
#                der Einstieg ist das Hermes-Dashboard; hybrid = beide Stacks,
#                also Cockpit UND Dashboard),
#                DISPLAY_STACK= (OK|MISSING - VM-Desktop/noVNC provisioniert?),
#                GATEWAY_COCKPIT_URL= / GATEWAY_NOVNC_URL=,
#                GATEWAY_AGENT_URL= / GATEWAY_APPS_URL= (nur Hermes-Stack hermes|hybrid)
# Ein VNC-Passwort gibt es nicht: x11vnc laeuft mit -nopw, der Zugang ist der
# Firmen-Login am Gateway (ADR 5.6).
# =============================================================================
$ErrorActionPreference = 'Continue'

$remote = @'
set -u
# Engine dieses Users (VM-Default + Per-User-Override). Fehlt ki-os-engine,
# ist die VM claude - der bisherige Zustand.
eng="claude"
if [ -x /usr/local/bin/ki-os-engine ]; then
    eng="$(/usr/local/bin/ki-os-engine "$(id -un)" 2>/dev/null || echo claude)"
fi
echo "ENGINE=${eng}"
# display.env schreibt der Display-Stack (VM-Desktop hinter dem Gateway).
if grep -q '^NOVNC_PORT=' ~/.config/ki-os/display.env 2>/dev/null; then
    echo "DISPLAY_STACK=OK"
else
    echo "DISPLAY_STACK=MISSING"
fi
gc="$(grep '^GATEWAY_COCKPIT_URL=' ~/.config/ki-os/gateway.env 2>/dev/null | cut -d= -f2- || true)"
gn="$(grep '^GATEWAY_NOVNC_URL=' ~/.config/ki-os/gateway.env 2>/dev/null | cut -d= -f2- || true)"
ga="$(grep '^GATEWAY_AGENT_URL=' ~/.config/ki-os/gateway.env 2>/dev/null | cut -d= -f2- || true)"
gp="$(grep '^GATEWAY_APPS_URL=' ~/.config/ki-os/gateway.env 2>/dev/null | cut -d= -f2- || true)"
echo "GATEWAY_COCKPIT_URL=${gc:-MISSING}"
echo "GATEWAY_NOVNC_URL=${gn:-MISSING}"
# Als `case`, nicht als `[ ... ] && echo`: das Remote-Skript endet hier, und
# eine falsche Bedingung waere sein Exit-Code - der $LASTEXITCODE-Check
# meldete dann bei jedem claude-User faelschlich SSH_FAIL.
case "$eng" in
    hermes|hybrid) echo "GATEWAY_AGENT_URL=${ga:-MISSING}"; echo "GATEWAY_APPS_URL=${gp:-MISSING}" ;;
esac
'@ -replace "`r`n", "`n"

# Das Here-String geht per stdin an `bash -s`. Zwei Windows-Fallstricke, beide
# VM-seitig per `tr` weggeraeumt (der Remote-Snippet ist pure ASCII, darum ist
# das Loeschen der Bytes im ganzen Stream gefahrlos - muss so bleiben):
# 1. PowerShell haengt beim Pipen an ein natives Kommando einen CRLF-Terminator
#    an die LETZTE Zeile - bash bekam `fi\r` statt `fi` und brach mit
#    "unexpected end of file" ab, dadurch fehlten genau die Gateway-URLs
#    (Jennifer/heimatwerft 2026-08-17). Das -replace oben normalisiert nur die
#    INNEREN Zeilenenden, nicht diesen Terminator.
# 2. $OutputEncoding ist default eine UTF-8-Variante MIT BOM - die drei
#    BOM-Bytes landen VOR `set -u`, bash quittiert `set: command not found`
#    und der Gateway-Block laeuft nie (Marc/heimatwerft 2026-08-07). Das
#    UTF8Encoding($false) unten behebt das in pwsh 7, unter powershell.exe 5.1
#    kam der BOM trotzdem durch - darum stehen seine Oktalbytes \357\273\277
#    mit im tr-Satz.
$prevOutputEncoding = $OutputEncoding
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
try {
    $out = $remote | & ssh -o BatchMode=yes -o ConnectTimeout=10 ki-os-vm "tr -d '\r\357\273\277' | bash -s" 2>&1
} finally {
    $OutputEncoding = $prevOutputEncoding
}

if ($LASTEXITCODE -ne 0) {
    Write-Host "SSH_FAIL: $($out -join ' | ')"
    Write-Host "Diagnose (Permission denied / Timeout / Host-Key / Bad owner): references/ssh.md -> Smoketest."
    exit 1
}

Write-Host "SSH_OK"
$out | ForEach-Object { Write-Host $_ }

if ($out -match 'DISPLAY_STACK=MISSING') {
    Write-Host "WARN: display.env fehlt - Display-Stack fuer diesen User noch nicht provisioniert. Admin kontaktieren, danach hier weitermachen."
}

# Gateway-Mapping je Stack: Claude-Stack (claude|hybrid) braucht die Cockpit-URL,
# Hermes-Stack (hermes|hybrid) die Agent-URL - hybrid beide. Auf engine=hermes
# ist GATEWAY_COCKPIT_URL legitim leer (kein Cockpit).
$engLine = ($out | Where-Object { $_ -match '^ENGINE=' } | Select-Object -First 1)
$eng = if ($engLine) { ($engLine -replace '^ENGINE=', '') } else { 'claude' }
if (($eng -in @('claude','hybrid')) -and ($out -match 'GATEWAY_COCKPIT_URL=MISSING')) {
    Write-Host "WARN: gateway-VM, aber kein Gateway-Mapping (Cockpit) fuer diesen User - Admin kontaktieren (ki-os-fleet vm gateway-grant)."
}
if (($eng -in @('hermes','hybrid')) -and ($out -match 'GATEWAY_AGENT_URL=MISSING')) {
    Write-Host "WARN: gateway-VM, aber kein Gateway-Mapping (Agent-Dashboard) fuer diesen User - Admin kontaktieren (ki-os-fleet vm gateway-grant)."
}
if (($eng -in @('hermes','hybrid')) -and ($out -match 'GATEWAY_APPS_URL=MISSING')) {
    Write-Host "WARN: gateway-VM, aber kein Apps-Mapping (Artefakte) fuer diesen User - Admin kontaktieren (ki-os-fleet vm gateway-grant)."
}
