# =============================================================================
# get-vm-values.ps1 - Smoketest + pro-User-Werte in EINEM SSH-Roundtrip (Windows)
#
# Holt die Engine-Pakete der VM, den Zustand des VM-Desktops (Claude-Paket) und
# die Gateway-URLs des Users. Schlaegt die Verbindung fehl, wird der SSH-Fehler
# ausgegeben (Diagnose: references/ssh.md).
#
# PowerShell-5.1-kompatibel. Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File get-vm-values.ps1
# Nicht auf Pfad H (nur Hermes-Paket, ADR 22 Nr. 10): dort gibt es keinen
# SSH-Zugang vom Geraet - die URLs kommen aus `ki-os-fleet vm zugang`.
#
# Output-Marker: SSH_OK | SSH_FAIL,
#                PACKAGES= (hermes|claude|hermes,claude - ki-os-engine --packages;
#                VMs vor dem Rollout: Rueckfall auf die Praesenz der Pakete),
#                Claude-Paket: GATEWAY_COCKPIT_URL=, DISPLAY_STACK= (OK|MISSING|AUS -
#                VM-Desktop/noVNC; AUS = Option display aus, dann ohne noVNC-URL),
#                GATEWAY_NOVNC_URL=,
#                Hermes-Paket: GATEWAY_AGENT_URL= (Hermes-Desktop-App + Dashboard),
#                immer: GATEWAY_APPS_URL= (Artefakte hinter dem Firmen-Login)
# Ein VNC-Passwort gibt es nicht: x11vnc laeuft mit -nopw, der Zugang ist der
# Firmen-Login am Gateway (ADR 5.6).
# =============================================================================
$ErrorActionPreference = 'Continue'

$remote = @'
set -u
# Pakete aus der EINEN Auswahlstelle. Aeltere VMs kennen --packages nicht
# (Exit 2, leere Ausgabe): dann zaehlt, welches Paket auf der VM liegt.
pk=""
if [ -x /usr/local/bin/ki-os-engine ]; then
    for p in $(/usr/local/bin/ki-os-engine --packages 2>/dev/null); do
        case "$p" in hermes|claude) pk="${pk:+$pk,}$p" ;; esac
    done
fi
if [ -z "$pk" ]; then
    # Hermes: eigener Checkout oder der VM-Code (ADR 29)
    { [ -d ~/.hermes/hermes-agent ] || [ -d /usr/local/lib/hermes-agent ]; } && pk="hermes"
    if [ -x /usr/local/bin/mitarbyte ] || systemctl cat "mitarbyte-cockpit@$(id -un).service" >/dev/null 2>&1; then
        pk="${pk:+$pk,}claude"
    fi
fi
echo "PACKAGES=${pk}"
gw() { v="$(grep "^$1=" ~/.config/ki-os/gateway.env 2>/dev/null | head -1 | cut -d= -f2-)"; echo "$1=${v:-MISSING}"; }
case ",${pk}," in *,claude,*)
    gw GATEWAY_COCKPIT_URL
    if grep -qx aus /opt/mitarbyte/claude/display 2>/dev/null; then
        echo "DISPLAY_STACK=AUS"
    else
        if grep -q '^NOVNC_PORT=' ~/.config/ki-os/display.env 2>/dev/null; then echo "DISPLAY_STACK=OK"; else echo "DISPLAY_STACK=MISSING"; fi
        gw GATEWAY_NOVNC_URL
    fi ;;
esac
case ",${pk}," in *,hermes,*) gw GATEWAY_AGENT_URL ;; esac
gw GATEWAY_APPS_URL
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

# Auswertung ohne Paket-Logik: der Remote-Block nennt nur die URLs, die die
# Pakete dieser VM haben - jedes MISSING ist ein fehlendes Mapping.
if ($out -contains 'PACKAGES=') {
    Write-Host "WARN: keine Engine-Pakete auf der VM erkannt - Admin kontaktieren."
}
if ($out -match 'DISPLAY_STACK=MISSING') {
    Write-Host "WARN: display.env fehlt - VM-Desktop fuer diesen User noch nicht provisioniert. Admin kontaktieren, danach hier weitermachen."
}
foreach ($line in $out) {
    if ("$line" -match '^GATEWAY_([A-Z]+)_URL=MISSING$') {
        Write-Host "WARN: kein Gateway-Mapping ($($Matches[1])) fuer diesen User - Admin kontaktieren (ki-os-fleet vm gateway-grant)."
    }
}
