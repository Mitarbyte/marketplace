#!/usr/bin/env bash
# =============================================================================
# setup-mutagen.sh — Mutagen installieren + Daemon-Autostart + Session ki-os
# (macOS/Linux)
#
#   VM (Alpha, gewinnt Konflikte):  ki-os-vm:/home/<VM_USER>/KI-OS
#   Lokal (Beta):                   ~/KI-OS
#
# Ignore-Begruendung + Konflikt-Semantik: references/mutagen.md.
#
# Teilt der User seinen `Workspaces`-Ordner per Bind-Mount mit Kollegen, bekommt
# alles, was Mutagen VM-seitig anlegt, dessen Gruppe + group-schreibbare Modes.
# Das wird VM-seitig ERKANNT (setgid-Bit), nicht angenommen — Details unten.
#
# macOS-TCC: liegt der lokale Sync-Ordner in ~/Desktop, ~/Documents oder
# ~/Downloads (Bestands-Setups), braucht der Session-Watchdog eine eigene,
# freigegebene Shell — sonst kann er blockierte VM-Loeschungen nicht aufloesen
# (Details in Abschnitt 4 + references/mutagen.md -> "macOS-TCC").
#
# Usage:  setup-mutagen.sh [--vm-user <VM_USER>] [--recreate] [--shared-group <NAME>]
#
# --vm-user ist optional: das Skript erkennt den VM-User per SSH selbst (im
# selben Roundtrip wie die Shared-Group). Angeben nur, wenn SSH gerade nicht
# erreichbar ist UND die Session neu angelegt werden muss.
#
# Output-Marker: SESSION_EXISTS | SESSION_CREATED | SESSION_RECREATED
# =============================================================================
set -euo pipefail

VM_USER="" RECREATE=0
# Shared-Group: leer = auto-detect (s. VM-Erkennung unten). Nur ein explizites
# --shared-group ueberstimmt die Erkennung ('' erzwingt aus).
# Begruendung: references/mutagen.md -> "Shared-Group".
SHARED_GROUP="" SHARED_GROUP_SET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --vm-user)      VM_USER="$2"; shift 2 ;;
        --recreate)     RECREATE=1; shift ;;
        --shared-group) SHARED_GROUP="$2"; SHARED_GROUP_SET=1; shift 2 ;;
        *) echo "FAIL: unbekanntes Argument: $1" >&2; exit 2 ;;
    esac
done

OS="$(uname -s)"

# --- VM-User + Shared-Group in EINEM SSH-Roundtrip erkennen ---------------------
# VM-User: fuer den Default-Alpha-Endpunkt bei Neuanlage (bei bestehender
# Session unnoetig — deshalb ist das Fehlen erst im Create-Pfad ein Fehler).
# Shared-Group: ein geteilter `Workspaces`-Bind-Mount ist auf der VM als
# setgid-Verzeichnis (drwxrws---, Modus 2770) mit der geteilten Gruppe
# angelegt — genau daran ist er erkennbar. Deshalb wird NICHTS angenommen:
# kein geteilter Ordner -> keine Gruppen-Freigabe (Normalfall, Single-User-
# und Multi-User-VMs ohne Sharing). Der Grund fuer die explizite Gruppe
# (Mutagen staged ausserhalb des Roots und renamed hinein, setgid vererbt
# dabei nicht): references/mutagen.md.
# Exit-Codes: 255 = SSH-Transportfehler (laut warnen statt still annehmen);
# alles andere (auch 1 = Workspaces-Ordner fehlt) ist auswertbar — Zeile 1 ist
# der VM-User, Zeile 2 (falls vorhanden) die setgid-Gruppe.
detect_vm_values() {
    # Bewusst ohne Quotes/Redirects im Remote-Kommando: es muss durch die
    # sh- UND die PowerShell-Variante identisch durchgehen.
    ssh -o BatchMode=yes -o ConnectTimeout=10 ki-os-vm \
        "id -un && find \$HOME/KI-OS/Workspaces -maxdepth 0 -perm -2000 -printf %g" 2>/dev/null
}

if [ -z "$VM_USER" ] || [ "$SHARED_GROUP_SET" -eq 0 ]; then
    REMOTE_OUT="$(detect_vm_values)" && DETECT_RC=0 || DETECT_RC=$?
    if [ "$DETECT_RC" -eq 255 ]; then
        echo "WARN: VM-Erkennung fehlgeschlagen (SSH nicht erreichbar)."
        echo "      Es wird KEINE Gruppen-Freigabe gesetzt. Teilst du deinen"
        echo "      Workspaces-Ordner mit Kollegen, den Schritt mit"
        echo "      --shared-group <NAME> wiederholen."
    else
        DETECTED_USER="$(printf '%s\n' "$REMOTE_OUT" | sed -n 1p)"
        DETECTED_GROUP="$(printf '%s\n' "$REMOTE_OUT" | sed -n 2p)"
        if [ -z "$VM_USER" ] && [ -n "$DETECTED_USER" ]; then
            VM_USER="$DETECTED_USER"
            echo "OK: VM-User '${VM_USER}' erkannt."
        fi
        if [ "$SHARED_GROUP_SET" -eq 0 ] && [ -n "$DETECTED_GROUP" ]; then
            SHARED_GROUP="$DETECTED_GROUP"
            echo "OK: geteilter Workspaces-Ordner erkannt — Shared-Group '${SHARED_GROUP}'."
        fi
    fi
fi

# --- 1. Installieren ----------------------------------------------------------
if ! command -v mutagen >/dev/null 2>&1; then
    case "$OS" in
        Darwin)
            command -v brew >/dev/null 2>&1 || {
                echo "FAIL: Homebrew fehlt — erst https://brew.sh folgen, dann diesen Schritt wiederholen." >&2
                exit 1
            }
            # Homebrews "trusted tap"-Gate (neuere brew-Versionen) blockiert sonst
            # den Install, weil der Tap auch mutagen-beta enthaelt. No-op auf
            # aelteren brew ohne 'trust'-Subcommand.
            brew trust mutagen-io/mutagen >/dev/null 2>&1 || true
            brew install mutagen-io/mutagen/mutagen
            ;;
        Linux)
            if command -v brew >/dev/null 2>&1; then
                brew trust mutagen-io/mutagen >/dev/null 2>&1 || true
                brew install mutagen-io/mutagen/mutagen
            else
                mkdir -p "$HOME/.local/bin"
                case "$(uname -m)" in
                    aarch64|arm64) ARCH=linux_arm64 ;;
                    *)             ARCH=linux_amd64 ;;
                esac
                URL="$(curl -fsSL https://api.github.com/repos/mutagen-io/mutagen/releases/latest \
                    | grep -o "\"browser_download_url\": *\"[^\"]*${ARCH}[^\"]*\"" \
                    | grep -o 'https[^"]*' | grep -v sidecar | head -1)"
                [ -n "$URL" ] || { echo "FAIL: Mutagen-Release-URL nicht gefunden." >&2; exit 1; }
                curl -fsSL "$URL" | tar -xz -C "$HOME/.local/bin" mutagen
                chmod +x "$HOME/.local/bin/mutagen"
                export PATH="$HOME/.local/bin:$PATH"
            fi
            ;;
    esac
fi
MUTAGEN_BIN="$(command -v mutagen)"
echo "OK: mutagen $("$MUTAGEN_BIN" version 2>/dev/null | head -1) (${MUTAGEN_BIN})"

# --- 2. Daemon-Autostart --------------------------------------------------------
if [ "$OS" = "Darwin" ]; then
    "$MUTAGEN_BIN" daemon register >/dev/null 2>&1 || true   # offizielle launchd-Integration
    "$MUTAGEN_BIN" daemon start   >/dev/null 2>&1 || true
    echo "OK: Daemon-Autostart (launchd, mutagen daemon register)"
else
    # 'daemon register' unterstuetzt Linux nicht -> systemd-User-Service
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/mutagen-daemon.service" <<UNIT
[Unit]
Description=Mutagen-Daemon (Sync-Sessions)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${MUTAGEN_BIN} daemon run
Restart=always
RestartSec=30

[Install]
WantedBy=default.target
UNIT
    "$MUTAGEN_BIN" daemon stop >/dev/null 2>&1 || true   # CLI-gestarteten Daemon abloesen
    systemctl --user daemon-reload
    systemctl --user enable --now mutagen-daemon.service
    # Linger, damit Daemon + Watchdog-Timer NICHT beim Logout stoppen und erst
    # beim naechsten Login wieder anlaufen. Im tunnel-Modus setzt das
    # setup-tunnels.sh; im gateway-Modus laeuft der aber nicht -> hier absichern
    # (idempotent, eigener User braucht i.d.R. kein root).
    loginctl enable-linger "$(id -un)" >/dev/null 2>&1 \
        || echo "WARN: loginctl enable-linger fehlgeschlagen — Sync stoppt evtl. beim Logout (einmalig: sudo loginctl enable-linger $(id -un))"
    echo "OK: Daemon-Autostart (systemd-User-Service mutagen-daemon.service)"
fi

# --- 3. Session ki-os ----------------------------------------------------------
create_session() {
    # Endpunkte: $1/$2 ueberschreiben die Konvention. Das ist fuer --recreate
    # PFLICHT, nicht Komfort — ein Bestands-Setup kann einen anderen SSH-Alias und
    # einen anderen lokalen Ordner haben (z.B. ~/Desktop/KI-OS). Wuerde die
    # Neuanlage stur die Konvention nehmen, terminiert sie die funktionierende
    # Session und legt eine neue auf einen fremden Alias + fast leeren Ordner an.
    _alpha="${1:-ki-os-vm:/home/${VM_USER}/KI-OS}"
    _beta="${2:-$HOME/KI-OS}"

    # VM ist Alpha (gewinnt bei Konflikten), lokal ist Beta. .claude/skills wird
    # auf macOS/Linux bewusst mitgesynct (relative Skill-Symlinks -> klickbare
    # Skill-Ansicht); Details: references/mutagen.md.
    #
    # Cloud-Sync-Ordner (root-verankert, fuehrender Slash): diese Ordner
    # gehoeren dem VM-seitigen Cloud-Sync und duerfen NICHT zusaetzlich durch
    # Mutagen laufen — sonst haengen an denselben Bytes drei Sync-Engines mit
    # zwei unabhaengigen Konfliktmodellen (Mutagen VM<->Client, Cloud-Client
    # VM<->Cloud, Cloud-Client der Kollegen an derselben Bibliothek). Der
    # Ordner liegt ueber die Cloud ohnehin schon auf jedem Arbeitsplatz.
    # Root-verankert, damit nicht zufaellig gleichnamige Unterordner irgendwo
    # im Baum mit ausgeschlossen werden.
    #
    # Vier Literale, weil der Ordnername Historie hat und nicht pro VM
    # konfigurierbar sein soll:
    #   /Ablage       — aktuelle Konvention, providerneutral (M365 wie Google)
    #   /SharePoint   — Bestand (schleumer, live seit 2026-08-07, bleibt dort)
    #   /Sharepoint   — dieselbe Schreibweise mit kleinem p, real vergeben
    #   /Google Drive — Name, den Google Drive for Desktop selbst vergibt
    # Mutagen-Ignores sind CASE-SENSITIV: '/SharePoint' trifft einen Ordner
    # 'Sharepoint' nicht. Beide Schreibweisen zu listen ist der einzige Weg, das
    # ohne Umbenennen am Live-Sync abzudecken (aufgefallen 2026-08-12: Ordner
    # 'Sharepoint' lief unbemerkt doppelt, weil nur '/SharePoint' gelistet war).
    # Jedes Literal ist ein No-op, solange der Ordner nicht existiert; sie
    # kosten also nichts und sparen ein Migrationsfenster am Live-Sync.
    # Details: docs/features/cloud-sync/cloudsync-runbook.md (Template).
    set -- \
        --name=ki-os \
        --sync-mode=two-way-resolved \
        --ignore-vcs \
        --ignore="node_modules" \
        --ignore=".venv" \
        --ignore="__pycache__" \
        --ignore=".obsidian/workspace*" \
        --ignore="/Ablage" \
        --ignore="/SharePoint" \
        --ignore="/Sharepoint" \
        --ignore="/Google Drive" \
        --ignore=".cache" \
        --ignore="dist" \
        --ignore=".next" \
        --ignore=".DS_Store"
    # Shared-Group fuer den geteilten Bind-Mount `Workspaces`: Dateien, die
    # Mutagen VM-seitig anlegt, muessen fuer die anderen Mitarbeiter der Gruppe
    # les-/schreibbar sein - sonst laufen deren Agents in Permission-Fehler.
    # Nur alpha (VM); lokale Modes bleiben Default.
    if [ -n "$SHARED_GROUP" ]; then
        set -- "$@" \
            --default-group-alpha="$SHARED_GROUP" \
            --default-file-mode-alpha=0660 \
            --default-directory-mode-alpha=0770
    fi
    "$MUTAGEN_BIN" sync create "$@" "$_alpha" "$_beta"
}

# Endpunkte einer bestehenden Session auslesen (alpha-URL bzw. beta-URL).
session_endpoint() {   # $1 = Alpha|Beta
    "$MUTAGEN_BIN" sync list ki-os --long 2>/dev/null \
        | awk -v sec="^$1:" '$0 ~ sec {f=1;next} f && /URL:/{sub(/^[[:space:]]*URL:[[:space:]]*/,""); print; exit}'
}

if "$MUTAGEN_BIN" sync list ki-os >/dev/null 2>&1; then
    if [ "$RECREATE" -eq 1 ]; then
        # Endpunkte VOR dem terminate sichern — danach sind sie nicht mehr lesbar.
        OLD_ALPHA="$(session_endpoint Alpha)"
        OLD_BETA="$(session_endpoint Beta)"
        if [ -z "$OLD_ALPHA" ] || [ -z "$OLD_BETA" ]; then
            echo "FAIL: Endpunkte der bestehenden Session nicht lesbar — es wird NICHTS" >&2
            echo "      terminiert. Sonst entstuende eine Neuanlage auf geratenen" >&2
            echo "      Endpunkten. Pruefen: mutagen sync list ki-os --long" >&2
            exit 1
        fi
        DEF_ALPHA="ki-os-vm:/home/${VM_USER}/KI-OS"
        if [ "$OLD_ALPHA" != "$DEF_ALPHA" ] || [ "$OLD_BETA" != "$HOME/KI-OS" ]; then
            echo "OK: Endpunkte der bestehenden Session werden uebernommen (Bestands-Setup):"
            echo "    alpha: ${OLD_ALPHA}"
            echo "    beta:  ${OLD_BETA}"
        fi
        "$MUTAGEN_BIN" sync terminate ki-os
        create_session "$OLD_ALPHA" "$OLD_BETA"
        echo "SESSION_RECREATED: ki-os neu angelegt (${OLD_ALPHA} <-> ${OLD_BETA}; Dateien bleiben erhalten)."
    else
        echo "SESSION_EXISTS: ki-os laeuft bereits."
        # Konfig-Drift AKTIV melden: Ignores/Group einer bestehenden Session sind
        # unveraenderlich, ein blosser Re-Run heilt sie NICHT.
        CFG="$("$MUTAGEN_BIN" sync list ki-os --long 2>&1 || true)"
        DRIFT=""
        # Cloud-Sync-Ignores: fehlt einer, laeuft der betroffene Ordner doppelt
        # (Mutagen + Cloud-Client). Das faellt sonst NICHT auf — der Sync sieht
        # gesund aus und produziert still Konfliktkopien. `sync list --long`
        # listet jeden Ignore auf einer eigenen, eingerueckten Zeile.
        # Gemeldet wird jedes fehlende Literal einzeln: Sessions, die vor der
        # Umbenennung auf 'Ablage' angelegt wurden, kennen nur '/SharePoint'.
        # Das ist erst dann ein echter Ausfall, wenn der jeweilige Ordner auf
        # der VM auch benutzt wird — deshalb Hinweis statt Alarm.
        for _ign in "/Ablage" "/SharePoint" "/Sharepoint" "/Google Drive"; do
            if ! printf '%s\n' "$CFG" | grep -qE "^[[:space:]]+${_ign}[[:space:]]*\$"; then
                DRIFT="${DRIFT}  - Ignore '${_ign}' fehlt (Cloud-Sync-Ordner wuerde doppelt gesynct, falls auf dieser VM genutzt)\n"
            fi
        done
        if [ -n "$SHARED_GROUP" ] \
           && ! printf '%s\n' "$CFG" | grep -qE "Default file/directory group:[[:space:]]*${SHARED_GROUP}\$"; then
            DRIFT="${DRIFT}  - Shared-Group '${SHARED_GROUP}' auf alpha fehlt (geteilter Workspaces-Bind-Mount)\n"
        fi
        if [ -n "$DRIFT" ]; then
            echo "DRIFT: die bestehende Session weicht vom Template ab:"
            printf '%b' "$DRIFT"
            echo "  -> einmalig mit --recreate neu anlegen (Dateien bleiben erhalten)."
            echo "  -> VORHER pruefen, dass beide Seiten konvergiert sind ('mutagen sync list ki-os':"
            echo "     gleiche Datei-/Verzeichniszahl auf alpha und beta) — sonst spuelt der frische"
            echo "     Ancestor lokal-only Daten als Neuanlage auf die VM."
        else
            echo "OK: Session-Konfiguration entspricht dem Template."
        fi
    fi
else
    # Nur die NEUANLAGE braucht den VM-User (Default-Alpha-Endpunkt) — erst
    # hier ist sein Fehlen ein Fehler, nicht schon beim Start.
    [ -n "$VM_USER" ] || {
        echo "FAIL: VM-User unbekannt — SSH-Erkennung fehlgeschlagen und --vm-user" >&2
        echo "      nicht angegeben. Neuanlage braucht den VM-Pfad: erst SSH fixen" >&2
        echo "      (ssh ki-os-vm) oder --vm-user <NAME> mitgeben." >&2
        exit 1
    }
    create_session
    echo "SESSION_CREATED: ki-os (VM:/home/${VM_USER}/KI-OS <-> ~/KI-OS)"
fi

# --- 4. Session-Watchdog (Selbstheilung: resume bei paused/halted) ------------
# Der Daemon-Autostart aus Schritt 2 haelt nur den *Prozess* am Leben. Eine
# Session, die nach langem VM-Idle-Suspend in paused/halted laeuft, heilt sich
# NICHT von selbst (Mutagens Eigen-Reconnect greift nur bei transienten
# Transport-Abrissen) — VM-seitig erscheint dann ein toter mutagen-agent und
# lokale Skill-Outputs kommen nicht mehr an. Ein kleiner 2-Min-Guard resumt sie.
# Windows deckt dasselbe ueber ki-os-vm-watchdog ab (setup-tunnels.ps1).
GUARD="$HOME/.local/bin/ki-os-mutagen-watchdog.sh"
mkdir -p "$HOME/.local/bin"
cat > "$GUARD" <<'GUARD_EOF'
#!/usr/bin/env bash
# ki-os-mutagen-watchdog.sh — generiert von setup-mutagen.sh.
# Haelt Mutagen-Daemon + Session 'ki-os' selbstheilend; laeuft alle ~2 min
# (launchd StartInterval / systemd-Timer).
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
command -v mutagen >/dev/null 2>&1 || exit 0
mutagen daemon start >/dev/null 2>&1 || true   # no-op wenn Daemon laeuft
info="$(mutagen sync list ki-os 2>/dev/null)" || exit 0
# Session gar nicht vorhanden -> nicht hier neu anlegen (braucht den VM-Pfad);
# das ist ein Setup-Fall -> /user-onboarding erneut laufen lassen.
[ -n "$info" ] || exit 0
# Steady-State 'Watching for changes' = gesund -> nichts tun. Jeder andere
# Zustand (Paused/Halted/abgerissen) -> resume. resume ist idempotent (no-op
# auf laufender/scannender Session), heilt aber paused/halted.
printf '%s\n' "$info" | grep -q 'Watching for changes' \
    || mutagen sync resume ki-os >/dev/null 2>&1 || true

# --- Blockierte VM-Loeschungen aufloesen --------------------------------------
# Raeumt ein Agent auf der VM einen Ordner weg, loescht Mutagen ihn lokal NICHT,
# solange darin ignorierte Dateien liegen (.DS_Store legt der Finder in jeden
# angesehenen Ordner!). Es entsteht ein Konflikt
#     (alpha) X            (Directory -> <non-existent>)
#     (beta)  X/y/.DS_Store (<non-existent> -> Untracked content)
# und der Ordner bleibt lokal KOMPLETT stehen — inkl. aller getrackten Dateien.
# Eine einzige ignorierte Datei tief im Baum reicht dafuer. Ohne Eingriff
# divergieren beide Seiten dauerhaft still.
# Fix: den betroffenen Ordner KOMPLETT in einen lokalen Papierkorb verschieben.
# Danach sind beide Seiten einig ("beidseitig weg") und der Konflikt ist erledigt.
#
# Warum komplett und nicht nur die Reste: Raeumt man nur die Reste weg, loescht
# Mutagen den Rest des Baums selbst — und nimmt dabei auch Dateien mit, die es
# NUR lokal gibt (bei two-way-resolved gewinnt alpha, ohne Rueckfrage, ohne
# Sicherung). Real aufgetreten: in einem migrierten Ordner lag noch ein
# SQL-Dump, den es auf der VM nirgends gab. Der Papierkorb ist die einzige
# Variante, bei der garantiert nichts verloren geht (mv = Rename, also auch bei
# node_modules billig).
#
# Nur wenn ALLE gemeldeten Reste Wegwerf-Artefakte sind (unsere Ignores ohne
# VCS). Ist .git betroffen, wird NICHT angefasst, sondern gemeldet: dort steckt
# in der Regel ein lokaler Repo-Klon, in dem der User aktiv arbeitet — der darf
# ihm nicht unter den Haenden wegwandern.
STATE="${HOME}/.local/state/ki-os"
TRASH_ROOT="${STATE}/sync-trash"
TRASH="${TRASH_ROOT}/$(date +%Y-%m-%d_%H%M%S)"

# Auffaelligkeiten (fehlgeschlagene Aufloesung, nicht anfassbare Reste) sammeln
# und erst am Ende melden — und dort nur, wenn sie sich seit dem letzten Lauf
# GEAENDERT haben. Der Watchdog laeuft alle 2 min; ein Dauerproblem wuerde das
# Log sonst mit derselben Meldung fluten und dabei genau das verdecken, was neu
# ist. Datei statt Variable, weil die Auswertung unten in einer Pipe-Subshell
# laeuft (Variablen kaemen dort nicht heraus).
ISSUES="${STATE}/watchdog-issues.tmp"
ISSUES_LAST="${STATE}/watchdog-issues.last"
mkdir -p "$STATE" 2>/dev/null || true
: > "$ISSUES" 2>/dev/null || true
note() { printf '%s\n' "$1" >> "$ISSUES" 2>/dev/null || true; }

full="$(mutagen sync list ki-os --long 2>/dev/null)"
conf="$(printf '%s\n' "$full" | sed -n '/^Conflicts:/,/^Status:/p')"
if [ -z "$conf" ]; then
    # Keine Konflikte = sauberer Zustand. Auch die Merkdatei zuruecksetzen, damit
    # ein spaeter WIEDER auftretendes Problem erneut gemeldet wird.
    rm -f "$ISSUES" "$ISSUES_LAST" 2>/dev/null || true
    exit 0
fi
# Lokalen Sync-Ordner AUS DER SESSION lesen, nicht $HOME/KI-OS annehmen: der
# Skill legt zwar ~/KI-OS an, aber Bestands-Setups haben ihn woanders (z.B.
# ~/Desktop/KI-OS). Mit falscher Wurzel findet der Aufloeser nichts und tut
# still nichts - der Bug faellt nicht auf, weil er wie "nichts zu tun" aussieht.
LOCAL_ROOT="$(printf '%s\n' "$full" | awk '/^Beta:/{f=1;next} f && /URL:/{sub(/^[[:space:]]*URL:[[:space:]]*/,""); print; exit}')"
[ -n "$LOCAL_ROOT" ] && [ -d "$LOCAL_ROOT" ] || LOCAL_ROOT="${HOME}/KI-OS"

disposable() {
    case "/$1/" in
        */.DS_Store/*|*/Thumbs.db/*|*/node_modules/*|*/__pycache__/*) return 0 ;;
        */.venv/*|*/.cache/*|*/dist/*|*/.next/*) return 0 ;;
    esac
    return 1
}

# Konflikt-Bloecke sind durch Leerzeilen getrennt: blockweise auswerten, damit
# ein .git in Block A nicht die Aufloesung von Block B verhindert (und
# umgekehrt kein Block halb aufgeloest wird).
printf '%s\n' "$conf" | awk -v RS='' '{print; print "---BLOCK---"}' | {
    block=""
    while IFS= read -r line; do
        if [ "$line" != "---BLOCK---" ]; then
            block="${block}${line}
"
            continue
        fi
        # Welchen Ordner hat alpha geloescht? (Nur Directory-Faelle: bei Dateien
        # gibt es das Untracked-Problem nicht.)
        target="$(printf '%s' "$block" | sed -n 's/^[[:space:]]*(alpha)[[:space:]]*\(.*\) (Directory -> <non-existent>)$/\1/p' | head -1)"
        [ -n "$target" ] || { block=""; continue; }
        # Alle beta-Pfade dieses Blocks, die als ignorierter Rest gemeldet sind.
        # sed greedy bis zum letzten Klammerausdruck -> Pfade mit Leerzeichen ok.
        betas="$(printf '%s' "$block" | sed -n 's/^[[:space:]]*(beta)[[:space:]]*\(.*\) (<non-existent> -> Untracked content)$/\1/p')"
        [ -n "$betas" ] || { block=""; continue; }
        # Nur aufloesen, wenn JEDER Rest ein Wegwerf-Artefakt ist.
        allowed=1
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            disposable "$p" || { allowed=0; note "SYNC-BLOCK: '$p' ist kein Wegwerf-Artefakt (z.B. .git) — bitte lokal selbst entscheiden."; }
        done <<EOF2
$betas
EOF2
        [ "$allowed" -eq 1 ] || { block=""; continue; }
        src="${LOCAL_ROOT}/${target}"
        [ -e "$src" ] || { block=""; continue; }
        if [ "${KIOS_SYNC_RESOLVE_DRYRUN:-0}" = "1" ]; then
            echo "DRYRUN: wuerde '${target}' komplett nach ${TRASH}/ verschieben (auf der VM geloescht, lokal durch ignorierte Reste blockiert)"
            block=""; continue
        fi
        mkdir -p "${TRASH}/$(dirname "$target")" 2>/dev/null || true
        # mv-Fehler NICHT verschlucken: solange er nach /dev/null ging, sah ein
        # dauerhaft blockierter Watchdog wie "nichts zu tun" aus (leeres Log) und
        # hinterliess bei jedem Lauf nur den leeren Zielordner von mkdir.
        if err="$(mv "$src" "${TRASH}/${target}" 2>&1)"; then
            echo "SYNC-FIX: '${target}' war auf der VM geloescht und lokal durch ignorierte Reste blockiert"
            echo "          -> komplett gesichert nach ${TRASH}/${target}"
            echo "          -> Sync ist jetzt konsistent. Papierkorb pruefen und bei Bedarf leeren."
            : > "${TRASH}/.did"
        else
            note "SYNC-FAIL: '${target}' konnte nicht in den Papierkorb verschoben werden."
            note "           ${err}"
            case "$err" in
                *"Operation not permitted"*|*"not permitted"*)
                    note "           -> Das ist macOS-TCC: der lokale Sync-Ordner liegt in einem"
                    note "              geschuetzten Bereich (~/Desktop, ~/Documents, ~/Downloads) und"
                    note "              der Watchdog laeuft als LaunchAgent. Freigabe erteilen:"
                    note "              Systemeinstellungen -> Datenschutz & Sicherheit ->"
                    note "              Festplattenvollzugriff -> ~/.local/bin/ki-os-watchdog-shell"
                    note "              hinzufuegen und aktivieren (Cmd+Shift+G im Auswahldialog)."
                    note "              Alternative: Sync-Ordner nach ~/KI-OS umziehen (/user-onboarding)."
                    ;;
            esac
        fi
        block=""
    done
}
# Flush nur anstossen, wenn wirklich etwas aufgeloest wurde (die Loeschung laeuft
# dann sofort statt erst beim naechsten Zyklus).
[ -f "${TRASH}/.did" ] && { rm -f "${TRASH}/.did"; mutagen sync flush ki-os >/dev/null 2>&1 || true; }

# --- Leere Papierkorb-Ordner aufraeumen ---------------------------------------
# Scheitert das mv, bleibt der per mkdir vorbereitete Zielpfad leer zurueck —
# und weil der Watchdog alle 2 min laeuft, wird daraus bei einem Dauerproblem
# ein Ordner-Regen (real aufgetreten: 3708 leere Ordner in 8 Tagen). Nur
# VOLLSTAENDIG leere Verzeichnisse werden entfernt, echte Sicherungen bleiben
# unangetastet. Mehrere Durchlaeufe, weil ein Parent erst dann als leer gilt,
# wenn seine Kinder im vorherigen Durchlauf verschwunden sind.
if [ -d "$TRASH_ROOT" ]; then
    _i=0
    while [ "$_i" -lt 8 ]; do
        find "$TRASH_ROOT" -mindepth 1 -depth -type d -empty -delete 2>/dev/null || true
        _i=$((_i + 1))
    done
fi

# --- Auffaelligkeiten melden (nur bei Aenderung, s. oben) ---------------------
if [ -s "$ISSUES" ]; then
    if ! cmp -s "$ISSUES" "$ISSUES_LAST" 2>/dev/null; then
        cat "$ISSUES"
        cp "$ISSUES" "$ISSUES_LAST" 2>/dev/null || true
    fi
else
    rm -f "$ISSUES_LAST" 2>/dev/null || true
fi
rm -f "$ISSUES" 2>/dev/null || true
true
GUARD_EOF
chmod +x "$GUARD"

if [ "$OS" = "Darwin" ]; then
    WD_LABEL="com.$(id -un).ki-os-vm.mutagen-watchdog"
    WD_PLIST="$HOME/Library/LaunchAgents/${WD_LABEL}.plist"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

    # --- Eigene Watchdog-Shell (macOS-TCC) ------------------------------------
    # Ein LaunchAgent, der ueber /bin/bash laeuft, hat in ~/Desktop, ~/Documents
    # und ~/Downloads KEINEN Zugriff auf fremd erzeugte Inhalte: stat und mkdir
    # gehen durch, aber opendir und das rename fremder Objekte geben EPERM. Liegt
    # der lokale Sync-Ordner dort (Bestands-Setups vor der ~/KI-OS-Konvention),
    # kann der Watchdog blockierte VM-Loeschungen nicht aufloesen.
    # Der Watchdog laeuft deshalb ueber eine EIGENE Kopie der Shell, die der User
    # einmalig im Festplattenvollzugriff freigibt — statt /bin/bash global
    # freizugeben, womit JEDES bash-Skript auf dem Rechner diese Rechte haette.
    # Existiert die Kopie schon, wird sie NICHT ersetzt: ein neues Binary am
    # selben Pfad invalidiert den erteilten TCC-Grant.
    # Die Kopie MUSS ad-hoc neu signiert werden: /bin/bash ist ein Apple-Platform-
    # Binary, dessen Signatur nur am Originalpfad validiert — eine unsignierte
    # Kopie killt der Kernel beim Start sofort (SIGKILL, "Killed: 9").
    WD_SHELL="$HOME/.local/bin/ki-os-watchdog-shell"
    if [ ! -x "$WD_SHELL" ] || ! "$WD_SHELL" -c true 2>/dev/null; then
        rm -f "$WD_SHELL" 2>/dev/null || true
        if cp /bin/bash "$WD_SHELL" 2>/dev/null \
           && chmod +x "$WD_SHELL" 2>/dev/null \
           && codesign --force --sign - "$WD_SHELL" >/dev/null 2>&1 \
           && "$WD_SHELL" -c true 2>/dev/null; then
            echo "OK: Watchdog-Shell angelegt (${WD_SHELL}, ad-hoc signiert)"
        else
            rm -f "$WD_SHELL" 2>/dev/null || true
            WD_SHELL="/bin/bash"
            echo "WARN: eigene Watchdog-Shell nicht anlegbar — fallback /bin/bash."
            echo "      In geschuetzten Ordnern (~/Desktop, ~/Documents, ~/Downloads) muesste"
            echo "      dann /bin/bash selbst Festplattenvollzugriff bekommen — oder der"
            echo "      Sync-Ordner nach ~/KI-OS umziehen."
        fi
    fi

    cat > "$WD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${WD_LABEL}</string>
    <key>ProgramArguments</key>
    <array><string>${WD_SHELL}</string><string>${GUARD}</string></array>
    <key>EnvironmentVariables</key>
    <dict><key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
    <key>RunAtLoad</key><true/>
    <key>StartInterval</key><integer>120</integer>
    <key>StandardOutPath</key><string>${HOME}/Library/Logs/ki-os-mutagen-watchdog.log</string>
    <key>StandardErrorPath</key><string>${HOME}/Library/Logs/ki-os-mutagen-watchdog.err.log</string>
    <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST
    ISSUES_LAST="$HOME/.local/state/ki-os/watchdog-issues.last"
    rm -f "$ISSUES_LAST" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/${WD_LABEL}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$WD_PLIST"
    launchctl enable "gui/$(id -u)/${WD_LABEL}" 2>/dev/null || true
    echo "OK: Session-Watchdog (LaunchAgent ${WD_LABEL}, alle 120s, Shell ${WD_SHELL})"

    # --- Braucht der Watchdog doch eine TCC-Freigabe? -------------------------
    # Die eigene, ad-hoc signierte Shell reicht in der Praxis aus: getestet mit
    # Sync-Ordner unter ~/Desktop, sowohl bei bootstrap- als auch bei
    # Timer-Start durch launchd — opendir und rename fremder Objekte gehen
    # durch, wo /bin/bash EPERM bekommt. Deshalb wird hier NICHT praeventiv nach
    # dem Ordnerpfad gewarnt (das schickte User grundlos in die
    # Systemeinstellungen), sondern nur gemeldet, was nachgewiesen ist: ein
    # tatsaechlich mit EPERM gescheiterter Watchdog-Lauf. Durch RunAtLoad laeuft
    # er beim bootstrap sofort mit und legt watchdog-issues.last an.
    _w=0
    while [ "$_w" -lt 6 ] && [ ! -f "$ISSUES_LAST" ]; do sleep 1; _w=$((_w + 1)); done
    if [ -f "$ISSUES_LAST" ] && grep -q "not permitted" "$ISSUES_LAST" 2>/dev/null; then
        LOCAL_ROOT="$("$MUTAGEN_BIN" sync list ki-os --long 2>/dev/null \
            | awk '/^Beta:/{f=1;next} f && /URL:/{sub(/^[[:space:]]*URL:[[:space:]]*/,""); print; exit}')"
        echo "TCC_GRANT_NEEDED: der Watchdog ist an macOS-TCC gescheitert (EPERM in"
        echo "  ${LOCAL_ROOT:-dem lokalen Sync-Ordner}). Einmalig freigeben:"
        echo "    Systemeinstellungen -> Datenschutz & Sicherheit -> Festplattenvollzugriff"
        echo "    -> '+' -> im Dialog Cmd+Shift+G -> ${WD_SHELL} -> Schalter aktivieren"
        echo "  Der Sync selbst bleibt voll funktionsfaehig; es faellt nur die automatische"
        echo "  Konflikt-Aufloesung aus (Details: ~/Library/Logs/ki-os-mutagen-watchdog.log)."
        echo "  Dauerhafte Alternative: Sync-Ordner nach ~/KI-OS umziehen (nicht geschuetzt)."
    fi
else
    mkdir -p "$HOME/.config/systemd/user"
    cat > "$HOME/.config/systemd/user/ki-os-mutagen-watchdog.service" <<UNIT
[Unit]
Description=KI-OS Mutagen-Session-Watchdog (resume bei paused/halted)

[Service]
Type=oneshot
ExecStart=/bin/bash ${GUARD}
UNIT
    cat > "$HOME/.config/systemd/user/ki-os-mutagen-watchdog.timer" <<UNIT
[Unit]
Description=KI-OS Mutagen-Session-Watchdog alle 2 Minuten

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    systemctl --user daemon-reload
    systemctl --user enable --now ki-os-mutagen-watchdog.timer
    echo "OK: Session-Watchdog (systemd-Timer ki-os-mutagen-watchdog.timer, alle 2 min)"
fi

"$MUTAGEN_BIN" sync list ki-os || true
