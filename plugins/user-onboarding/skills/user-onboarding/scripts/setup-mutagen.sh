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
# Usage:  setup-mutagen.sh --vm-user <VM_USER> [--recreate] [--shared-group <NAME>]
#
# Output-Marker: SESSION_EXISTS | SESSION_CREATED | SESSION_RECREATED
# =============================================================================
set -euo pipefail

VM_USER="" RECREATE=0
# Shared-Group: leer = auto-detect (s. detect_shared_group). Nur ein explizites
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
[ -n "$VM_USER" ] || { echo "FAIL: --vm-user fehlt" >&2; exit 2; }

OS="$(uname -s)"

# --- Shared-Group VM-seitig erkennen ------------------------------------------
# Ein geteilter `Workspaces`-Bind-Mount ist auf der VM als setgid-Verzeichnis
# (drwxrws---, Modus 2770) mit der geteilten Gruppe angelegt — genau daran ist er
# erkennbar. Deshalb wird NICHTS angenommen: kein geteilter Ordner -> keine
# Gruppen-Freigabe (Normalfall, Single-User- und Multi-User-VMs ohne Sharing).
# Der Grund fuer die explizite Gruppe (Mutagen staged ausserhalb des Roots und
# renamed hinein, setgid vererbt dabei nicht): references/mutagen.md.
# find-Exit-Codes: 0 = setgid-Treffer (Gruppe auf stdout), 1 = Ordner fehlt,
# 255 = SSH-Transportfehler (dann laut warnen statt still "aus" annehmen).
detect_shared_group() {
    # Bewusst ohne Quotes/Redirects im Remote-Kommando: es muss durch die
    # sh- UND die PowerShell-Variante identisch durchgehen.
    ssh -o BatchMode=yes -o ConnectTimeout=10 ki-os-vm \
        "find \$HOME/KI-OS/Workspaces -maxdepth 0 -perm -2000 -printf %g" 2>/dev/null
}

if [ "$SHARED_GROUP_SET" -eq 0 ]; then
    DETECTED="$(detect_shared_group)" && DETECT_RC=0 || DETECT_RC=$?
    if [ "$DETECT_RC" -eq 255 ]; then
        echo "WARN: Shared-Group-Erkennung fehlgeschlagen (SSH nicht erreichbar)."
        echo "      Es wird KEINE Gruppen-Freigabe gesetzt. Teilst du deinen"
        echo "      Workspaces-Ordner mit Kollegen, den Schritt mit"
        echo "      --shared-group <NAME> wiederholen."
    elif [ -n "$DETECTED" ]; then
        SHARED_GROUP="$DETECTED"
        echo "OK: geteilter Workspaces-Ordner erkannt — Shared-Group '${SHARED_GROUP}'."
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
    # VM ist Alpha (gewinnt bei Konflikten), lokal ist Beta. .claude/skills wird
    # auf macOS/Linux bewusst mitgesynct (relative Skill-Symlinks -> klickbare
    # Skill-Ansicht); Details: references/mutagen.md.
    #
    # `/SharePoint` (root-verankert, fuehrender Slash): dieser Ordner gehoert
    # dem VM-seitigen Cloud-Sync (onedrive-Client, SharePoint-Bibliothek) und
    # darf NICHT zusaetzlich durch Mutagen laufen — sonst haengen an denselben
    # Bytes drei Sync-Engines mit zwei unabhaengigen Konfliktmodellen (Mutagen
    # VM<->Client, onedrive VM<->SharePoint, OneDrive-Client der Kollegen an
    # derselben Bibliothek). Der Ordner ist ueber SharePoint ohnehin schon auf
    # jedem Arbeitsplatz. Root-verankert, damit nicht zufaellig gleichnamige
    # Unterordner irgendwo im Baum mit ausgeschlossen werden.
    # Details: docs/features/sharepoint-sync/cloudsync-runbook.md (Template).
    set -- \
        --name=ki-os \
        --sync-mode=two-way-resolved \
        --ignore-vcs \
        --ignore="node_modules" \
        --ignore=".venv" \
        --ignore="__pycache__" \
        --ignore=".obsidian/workspace*" \
        --ignore="/SharePoint" \
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
    "$MUTAGEN_BIN" sync create "$@" \
        "ki-os-vm:/home/${VM_USER}/KI-OS" "$HOME/KI-OS"
}

if "$MUTAGEN_BIN" sync list ki-os >/dev/null 2>&1; then
    if [ "$RECREATE" -eq 1 ]; then
        "$MUTAGEN_BIN" sync terminate ki-os
        create_session
        echo "SESSION_RECREATED: ki-os neu angelegt (Dateien bleiben erhalten)."
    else
        echo "SESSION_EXISTS: ki-os laeuft bereits."
        # Konfig-Drift AKTIV melden: Ignores/Group einer bestehenden Session sind
        # unveraenderlich, ein blosser Re-Run heilt sie NICHT.
        CFG="$("$MUTAGEN_BIN" sync list ki-os --long 2>&1 || true)"
        DRIFT=""
        # `/SharePoint`-Ignore: fehlt er, laeuft der Cloud-Sync-Ordner doppelt
        # (Mutagen + onedrive). Das faellt sonst NICHT auf — der Sync sieht
        # gesund aus und produziert still Konfliktkopien. `sync list --long`
        # listet jeden Ignore auf einer eigenen, eingerueckten Zeile.
        if ! printf '%s\n' "$CFG" | grep -qE '^[[:space:]]+/SharePoint[[:space:]]*$'; then
            DRIFT="${DRIFT}  - Ignore '/SharePoint' fehlt (Cloud-Sync-Ordner wuerde doppelt gesynct)\n"
        fi
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
TRASH="${HOME}/.local/state/ki-os/sync-trash/$(date +%Y-%m-%d_%H%M%S)"
full="$(mutagen sync list ki-os --long 2>/dev/null)"
conf="$(printf '%s\n' "$full" | sed -n '/^Conflicts:/,/^Status:/p')"
[ -n "$conf" ] || exit 0
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
            disposable "$p" || { allowed=0; echo "SYNC-BLOCK: '$p' ist kein Wegwerf-Artefakt (z.B. .git) — bitte lokal selbst entscheiden."; }
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
        if mv "$src" "${TRASH}/${target}" 2>/dev/null; then
            echo "SYNC-FIX: '${target}' war auf der VM geloescht und lokal durch ignorierte Reste blockiert"
            echo "          -> komplett gesichert nach ${TRASH}/${target}"
            echo "          -> Sync ist jetzt konsistent. Papierkorb pruefen und bei Bedarf leeren."
            : > "${TRASH}/.did"
        fi
        block=""
    done
}
# Flush nur anstossen, wenn wirklich etwas aufgeloest wurde (die Loeschung laeuft
# dann sofort statt erst beim naechsten Zyklus).
[ -f "${TRASH}/.did" ] && { rm -f "${TRASH}/.did"; mutagen sync flush ki-os >/dev/null 2>&1 || true; }
true
GUARD_EOF
chmod +x "$GUARD"

if [ "$OS" = "Darwin" ]; then
    WD_LABEL="com.$(id -un).ki-os-vm.mutagen-watchdog"
    WD_PLIST="$HOME/Library/LaunchAgents/${WD_LABEL}.plist"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    cat > "$WD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${WD_LABEL}</string>
    <key>ProgramArguments</key>
    <array><string>/bin/bash</string><string>${GUARD}</string></array>
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
    launchctl bootout "gui/$(id -u)/${WD_LABEL}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$WD_PLIST"
    launchctl enable "gui/$(id -u)/${WD_LABEL}" 2>/dev/null || true
    echo "OK: Session-Watchdog (LaunchAgent ${WD_LABEL}, alle 120s)"
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
