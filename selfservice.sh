#!/usr/bin/env bash
# selfservice.sh — Kunden-One-Liner fuer das Selfservice-Onboarding (Phase 1).
#
# Der Kunde fuehrt das Skript als root im Hostinger-Browser-Terminal aus
# (Download-then-run, damit interaktives `read` sauber funktioniert):
#
#   curl -fsSL https://raw.githubusercontent.com/Mitarbyte/marketplace/main/selfservice.sh \
#     -o /root/mitarbyte.sh && bash /root/mitarbyte.sh
#
# Modi:
#   register  (Default)  FALLBACK seit Revision 2026-08-19: Der Normalweg ist
#                        das Registrierungs-Formular der Anleitung (Web3Forms;
#                        Bootstrap-Keys fuegt der Kunde im Hostinger-OS-Setup
#                        ein). Dieser Modus bleibt fuer Kunden, bei denen
#                        Formular oder Key-Feld nicht funktionieren:
#                        Guards (root, Ubuntu 22.04/24.04 hard, E5-Groesse
#                        weich) → Bootstrap-Keys append-dedupe nach
#                        /root/.ssh/authorized_keys → Kurz-Interview →
#                        /opt/mitarbyte/selfservice/registration.json →
#                        kopierfertige Klingel-Nachricht (fertiger
#                        `ki-os-fleet intake pull`-Befehl).
#   idp                  Anleitung Teil 3: IdP-Werte (Tenant-/Client-ID,
#                        Client-Secret via read -s) + Login-Mail pro User →
#                        root-only idp.env + users-idp.txt. Das Secret
#                        verlaesst die VM nie — der Motor liest es spaeter
#                        per @vm:-Referenz (ssh, Heredoc). Laeuft auch OHNE
#                        vorherige Registrierung (Formular-Pfad): dann werden
#                        IdP-Typ + User-Namen interaktiv abgefragt.
#   m365                 Anleitung Teil 5: Outlook/SharePoint-App (Tenant-/
#                        Client-ID, Client-Secret via read -s), SharePoint-
#                        Sites + nur-lesen, geteilte Postfaecher je User,
#                        optional Assistenten-Postfach → root-only m365.env +
#                        mailboxes-m365.txt. Secret bleibt auf der VM wie bei
#                        idp; `ki-os-fleet intake pull` + `mcp enable` holen
#                        die Werte per SSH.
#   revoke               Mitarbyte-Zugang entziehen: Bootstrap-Keys aus
#                        authorized_keys entfernen + /etc/ssh/ki-os_admin_keys
#                        leeren.
#
# Idempotent: Re-Runs laden bestehende Werte als Defaults. Registrierungs-
# Daten kommen seit Revision 2026-08-19 normal per Web3Forms-Formular
# (nie Secrets); die VM bleibt der Briefkasten fuer alles Uebrige —
# CLIENT_SECRET & Co. holt `ki-os-fleet intake pull` weiterhin nur per SSH.
#
# Source of Truth ist ki-os-template (scripts/selfservice/); ins Marketplace-
# Repo spiegelt scripts/sync-onboarding-plugin.sh. bash-3.2-kompatibel, damit
# die bats-Suite (macOS /bin/bash) die Funktionen direkt testen kann.
#
# Test-Hooks (nur fuer bats, im Kundeneinsatz ungesetzt):
#   SELFSERVICE_PREFIX      Pfad-Praefix fuer /opt, /root, /etc (+ skippt den root-Guard)
#   SELFSERVICE_OS_RELEASE  alternative os-release-Datei
#   SELFSERVICE_NPROC / SELFSERVICE_MEMINFO   Hardware-Werte injizieren
#   BOOTSTRAP_KEYS_URL      alternative Key-Quelle (file:// erlaubt)
#   MB_MGR                  Onboarding-Manager (komma-separiert), deren Keys
#                           eingetragen werden; leer = alle aus der Datei

if [ "${BASH_SOURCE[0]}" = "$0" ]; then set -euo pipefail; fi

BOOTSTRAP_KEYS_URL="${BOOTSTRAP_KEYS_URL:-https://raw.githubusercontent.com/Mitarbyte/marketplace/main/bootstrap-keys.pub}"

ss_init_paths() {
    SS_PREFIX="${SELFSERVICE_PREFIX:-}"
    SS_DIR="${SS_PREFIX}/opt/mitarbyte/selfservice"
    SS_REG="${SS_DIR}/registration.json"
    SS_IDP="${SS_DIR}/idp.env"
    SS_USERS_IDP="${SS_DIR}/users-idp.txt"
    SS_M365="${SS_DIR}/m365.env"
    SS_MAILBOXES_M365="${SS_DIR}/mailboxes-m365.txt"
    SS_AUTH_KEYS="${SS_PREFIX}/root/.ssh/authorized_keys"
    SS_ADMIN_KEYS="${SS_PREFIX}/etc/ssh/ki-os_admin_keys"
}

ss_die() { echo "FEHLER: $*" >&2; exit 1; }

# --- Validierung -------------------------------------------------------------

ss_valid_username() {
    printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]{1,30}$'
}

ss_valid_slug() {
    printf '%s' "$1" | grep -Eq '^[a-z0-9][a-z0-9-]*$'
}

ss_valid_guid() {
    printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

ss_valid_email() {
    printf '%s' "$1" | grep -Eq '^[^ @]+@[^ @]+\.[^ @]+$'
}

# SharePoint-Site-URL: https://<tenant>.sharepoint.com/(sites|teams)/<Name>
ss_valid_sp_site() {
    printf '%s' "$1" | grep -Eq '^https://[A-Za-z0-9-]+\.sharepoint\.com/(sites|teams)/[^ ,/]+$'
}

# Postfach-Adresse → Instanz-Slug (Local-Part, a-z0-9-). Byte-identisch zu
# _mcp_mailbox_slug in scripts/fleet-lib/mcp.sh (tests/mcp.bats haelt beide fest).
ss_mailbox_slug() {
    printf '%s' "${1%%@*}" | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-\{1,\}//' -e 's/-\{1,\}$//'
}

# Firmenname → Slug-Vorschlag (Umlaute transliteriert, Rest → '-')
ss_slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
        | sed -e 's/ä/ae/g' -e 's/ö/oe/g' -e 's/ü/ue/g' -e 's/ß/ss/g' \
        | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-\{1,\}//' -e 's/-\{1,\}$//'
}

# --- Guards ------------------------------------------------------------------

# OS pruefen: stdout "<id>-<version>", rc 0 nur bei Ubuntu 22.04/24.04.
ss_os_check() {
    local f="${1:-${SELFSERVICE_OS_RELEASE:-/etc/os-release}}" id ver
    id="$(sed -n 's/^ID=//p' "$f" 2>/dev/null | tr -d '"' | head -1)"
    ver="$(sed -n 's/^VERSION_ID=//p' "$f" 2>/dev/null | tr -d '"' | head -1)"
    printf '%s-%s' "${id:-unbekannt}" "${ver:-?}"
    case "${id}-${ver}" in
        ubuntu-22.04|ubuntu-24.04) return 0 ;;
        *) return 1 ;;
    esac
}

# E5-Groessen-Check (Warnung, kein Abbruch): $1 = Anzahl Mitarbeiter.
ss_hw_warn() {
    local n="${1:-1}" vcpu ram_mb req_vcpu req_gb plan mi ram_min
    vcpu="${SELFSERVICE_NPROC:-$(nproc 2>/dev/null || echo 0)}"
    mi="${SELFSERVICE_MEMINFO:-/proc/meminfo}"
    ram_mb=0
    if [ -r "$mi" ]; then
        ram_mb=$(( $(sed -n 's/^MemTotal: *\([0-9]*\) kB/\1/p' "$mi" | head -1) / 1024 ))
    fi
    if [ "$n" -le 2 ]; then req_vcpu=2; req_gb=8; plan="KVM 2"; else req_vcpu=4; req_gb=16; plan="KVM 4"; fi
    ram_min=$(( req_gb * 1024 * 9 / 10 ))
    if [ "$vcpu" -gt 0 ] && { [ "$vcpu" -lt "$req_vcpu" ] || [ "$ram_mb" -lt "$ram_min" ]; }; then
        echo ""
        echo "  HINWEIS: Diese VM hat ${vcpu} vCPU / $(( ram_mb / 1024 )) GB RAM — fuer ${n} Mitarbeiter"
        echo "  empfiehlt Mitarbyte mindestens ${plan} (${req_vcpu} vCPU / ${req_gb} GB)."
        echo "  Es geht trotzdem weiter; ein Upgrade ist in hPanel jederzeit moeglich."
    fi
    return 0
}

# --- Bootstrap-Keys ----------------------------------------------------------

# Keys aus $1 (Datei) append-dedupe nach $2 (authorized_keys).
# stdout: Anzahl neu eingetragener Keys.
ss_append_keys() {
    local src="$1" dst="$2" line sig added=0
    mkdir -p "$(dirname "$dst")"
    chmod 700 "$(dirname "$dst")" 2>/dev/null || true
    touch "$dst"
    chmod 600 "$dst"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        sig="$(printf '%s' "$line" | awk '{print $1" "$2}')"
        [ -n "$sig" ] || continue
        if ! grep -qF "$sig" "$dst"; then
            printf '%s\n' "$line" >> "$dst"
            added=$((added+1))
        fi
    done < "$src"
    echo "$added"
}

# MB_MGR (aus der Anleitung, komma-separiert) waehlt aus, welche Manager-Keys
# eingetragen werden — dieselbe Auswahl, die die Anleitung anzeigt. Gefiltert
# wird ueber den Key-Kommentar (<name>@mitarbyte.com). Ist MB_MGR leer, bleibt
# es beim bisherigen Verhalten: alle Keys der Datei.
ss_filter_bootstrap_keys() {
    local file="$1" want="${MB_MGR:-}" tmp line name keep
    [ -n "$want" ] || return 0
    tmp="${file}.sel"
    : > "$tmp"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        name="$(printf '%s' "$line" | awk '{print $NF}' | cut -d@ -f1)"
        keep=0
        case ",${want}," in *",${name},"*) keep=1 ;; esac
        [ "$keep" = 1 ] && printf '%s\n' "$line" >> "$tmp"
    done < "$file"
    if grep -q 'ssh-' "$tmp" 2>/dev/null; then
        mv "$tmp" "$file"
    else
        # Auswahl passt auf keinen Key (Tippfehler, alter Link): lieber alle
        # eintragen als den Kunden mit einer VM ohne Zugang zurueckzulassen.
        rm -f "$tmp"
        echo "[i] Manager-Auswahl '${want}' traf keinen Key — alle Mitarbyte-Keys werden eingetragen."
    fi
}

ss_fetch_bootstrap_keys() {
    local dest="$1"
    curl -fsSL "$BOOTSTRAP_KEYS_URL" -o "$dest" 2>/dev/null \
        || ss_die "Bootstrap-Keys nicht ladbar (${BOOTSTRAP_KEYS_URL}) — Internet-Zugang der VM pruefen, dann erneut ausfuehren."
    grep -q 'ssh-' "$dest" || ss_die "Bootstrap-Keys-Datei sieht nicht nach SSH-Keys aus — bitte Mitarbyte kontaktieren."
    ss_filter_bootstrap_keys "$dest"
}

# --- JSON-Helfer (flach, selbst geschriebenes Format — bewusst ohne jq:
# eine frische VPS hat kein jq, und wir kontrollieren beide Seiten) -----------

ss_json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Wert eines String-Feldes aus registration.json (eine Ebene, ein Feld pro Zeile).
ss_json_get() {
    sed -n 's/^ *"'"$2"'": *"\(.*\)",*$/\1/p' "$1" 2>/dev/null | head -1
}

# users-Array (eine Zeile) → space-separierte Liste.
ss_json_get_users() {
    sed -n 's/^ *"users": *\[\(.*\)\],*$/\1/p' "$1" 2>/dev/null | head -1 \
        | tr -d '" ' | tr ',' ' '
}

# registration.json schreiben (700/600). Nutzt REG_*-Globals.
ss_write_registration() {
    local f="$1" uj="" u
    for u in $REG_USERS; do uj="${uj:+${uj}, }\"${u}\""; done
    mkdir -p "$(dirname "$f")"
    chmod 700 "$(dirname "$f")" 2>/dev/null || true
    umask 077
    cat > "$f" <<EOF
{
  "schema": 1,
  "kunde": "$(ss_json_escape "$REG_KUNDE")",
  "company": "$(ss_json_escape "$REG_COMPANY")",
  "hostname": "$(ss_json_escape "$REG_HOSTNAME")",
  "ip": "$(ss_json_escape "$REG_IP")",
  "it_contact": "$(ss_json_escape "$REG_CONTACT")",
  "idp_type": "$(ss_json_escape "$REG_IDP_TYPE")",
  "users": [${uj}],
  "registered_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    chmod 600 "$f"
}

# --- Klingel-Nachricht -------------------------------------------------------

# $1 = Firma, $2 = Slug, $3 = Host (IP). Der Kunde kopiert die KOMPLETTE
# Nachricht — der Admin liest sie und fuehrt den Befehl aus (kein Parsing).
ss_bell_message() {
    cat <<EOF

------------------------------------------------------------------
 Fertige Nachricht an deinen Mitarbyte-Ansprechpartner —
 einfach KOMPLETT kopieren und senden (Mail oder Messenger, egal):

   Hallo! Unsere VM fuer das KI-OS ist registriert.
   Firma: ${1}
   Abholen mit: ki-os-fleet intake pull --kunde ${2} --host ${3}

------------------------------------------------------------------
EOF
}

# --- Interview-Helfer --------------------------------------------------------

# $1 = Prompt, $2 = Default → SS_ANSWER
ss_ask() {
    local v
    if [ -n "${2:-}" ]; then printf '%s [%s]: ' "$1" "$2"; else printf '%s: ' "$1"; fi
    IFS= read -r v || v=""
    [ -z "$v" ] && v="${2:-}"
    SS_ANSWER="$v"
}

ss_detect_hostname() {
    hostname -f 2>/dev/null || hostname 2>/dev/null || echo ""
}

ss_detect_ip() {
    hostname -I 2>/dev/null | awk '{print $1}'
}

# --- Modus: register ---------------------------------------------------------

ss_register() {
    echo ""
    echo "== Mitarbyte KI-OS — VM-Registrierung =="
    echo "   (3-4 kurze Fragen, dauert etwa eine Minute)"
    echo ""

    # 1) Bootstrap-Keys eintragen (append-dedupe, idempotent)
    local tmp added
    tmp="$(mktemp)" || ss_die "mktemp fehlgeschlagen"
    ss_fetch_bootstrap_keys "$tmp"
    added="$(ss_append_keys "$tmp" "$SS_AUTH_KEYS")"
    rm -f "$tmp"
    if [ "$added" -gt 0 ]; then
        echo "[ok] Mitarbyte-Zugang eingerichtet (${added} Key(s) eingetragen)."
    else
        echo "[ok] Mitarbyte-Zugang war schon eingerichtet (nichts zu tun)."
    fi

    # 2) Defaults aus bestehender Registrierung (Re-Run)
    local d_company="" d_kunde="" d_users="" d_contact="" d_idp="m365"
    if [ -f "$SS_REG" ]; then
        d_company="$(ss_json_get "$SS_REG" company)"
        d_kunde="$(ss_json_get "$SS_REG" kunde)"
        d_users="$(ss_json_get_users "$SS_REG")"
        d_contact="$(ss_json_get "$SS_REG" it_contact)"
        d_idp="$(ss_json_get "$SS_REG" idp_type)"
        echo "[i]  Bestehende Registrierung gefunden — Enter uebernimmt die bisherigen Werte."
    fi

    # 3) Interview
    while :; do
        ss_ask "Firmenname" "$d_company"
        REG_COMPANY="$SS_ANSWER"
        [ -n "$REG_COMPANY" ] && break
        echo "     Bitte einen Firmennamen angeben."
    done

    local slug_default
    slug_default="${d_kunde:-$(ss_slugify "$REG_COMPANY")}"
    while :; do
        ss_ask "Kurzname (Kleinbuchstaben/Ziffern/Bindestrich)" "$slug_default"
        REG_KUNDE="$SS_ANSWER"
        ss_valid_slug "$REG_KUNDE" && break
        echo "     Ungueltig — erlaubt: Kleinbuchstaben, Ziffern, Bindestrich (z.B. acme-gmbh)."
    done

    while :; do
        ss_ask "Gewuenschte User-Namen, durch Komma getrennt (z.B. max, erika)" "$d_users"
        REG_USERS="$(printf '%s' "$SS_ANSWER" | tr ',' ' ' | tr -s ' ')"
        local ok=1 u
        [ -n "$(printf '%s' "$REG_USERS" | tr -d ' ')" ] || ok=0
        for u in $REG_USERS; do
            ss_valid_username "$u" || { echo "     '${u}' ist ungueltig (Kleinbuchstaben/Ziffern/Bindestrich, 2-31 Zeichen, beginnt mit Buchstabe)."; ok=0; }
        done
        [ "$ok" = 1 ] && break
    done

    ss_ask "IT-Ansprechpartner (Name + E-Mail)" "$d_contact"
    REG_CONTACT="$SS_ANSWER"

    while :; do
        ss_ask "Nutzt ihr Microsoft 365, Google Workspace oder keins von beiden? (m365/google/keins)" "$d_idp"
        REG_IDP_TYPE="$(printf '%s' "$SS_ANSWER" | tr '[:upper:]' '[:lower:]')"
        case "$REG_IDP_TYPE" in m365|google|keins) break ;; esac
        echo "     Bitte m365, google oder keins eingeben."
    done

    # 4) Hardware-Hinweis (E5, weich)
    local n_users
    n_users="$(printf '%s\n' "$REG_USERS" | tr ' ' '\n' | grep -c . || true)"
    ss_hw_warn "$n_users"

    # 5) Registrierung schreiben + Klingel-Nachricht
    REG_HOSTNAME="$(ss_detect_hostname)"
    REG_IP="$(ss_detect_ip)"
    ss_write_registration "$SS_REG"
    echo ""
    echo "[ok] Registrierung gespeichert (${SS_REG})."
    ss_bell_message "$REG_COMPANY" "$REG_KUNDE" "${REG_IP:-$REG_HOSTNAME}"
    echo "Fertig — weiter mit dem nächsten Teil der Anleitung."
}

# --- Modus: idp (Anleitung Teil 3) -------------------------------------------

ss_idp() {
    local idp_type="" users=""
    if [ -f "$SS_REG" ]; then
        idp_type="$(ss_json_get "$SS_REG" idp_type)"
        users="$(ss_json_get_users "$SS_REG")"
    else
        # Formular-Pfad (Revision 2026-08-19): keine registration.json auf der
        # VM — IdP-Typ + User-Namen interaktiv abfragen, Rest wie gehabt.
        echo ""
        echo "[i]  Keine Registrierung auf dieser VM gefunden — kein Problem"
        echo "     (Registrierung lief per Formular). Zwei kurze Fragen vorab:"
        while :; do
            ss_ask "User-Namen wie im Registrierungs-Formular angegeben, durch Komma getrennt (z.B. max, erika)" ""
            users="$(printf '%s' "$SS_ANSWER" | tr ',' ' ' | tr -s ' ')"
            local ok=1 u
            [ -n "$(printf '%s' "$users" | tr -d ' ')" ] || ok=0
            for u in $users; do
                ss_valid_username "$u" || { echo "     '${u}' ist ungueltig (Kleinbuchstaben/Ziffern/Bindestrich, 2-31 Zeichen, beginnt mit Buchstabe)."; ok=0; }
            done
            [ "$ok" = 1 ] && break
        done
    fi

    if [ "$idp_type" = "keins" ] || [ -z "$idp_type" ]; then
        while :; do
            ss_ask "Nutzt ihr Microsoft 365 oder Google Workspace? (m365/google)" ""
            idp_type="$(printf '%s' "$SS_ANSWER" | tr '[:upper:]' '[:lower:]')"
            case "$idp_type" in m365|google) break ;; esac
        done
    fi

    echo ""
    echo "== Mitarbyte KI-OS — Firmen-Login-Werte hinterlegen (Teil 3) =="
    echo "   Die Werte bleiben auf DIESER VM (root-only) — nichts davon wird gemailt."
    echo ""

    # Defaults aus bestehender idp.env (Re-Run)
    local d_tenant="" d_client="" d_secret="" d_csapp=""
    if [ -f "$SS_IDP" ]; then
        d_tenant="$(sed -n 's/^TENANT_ID=//p' "$SS_IDP" | head -1)"
        d_client="$(sed -n 's/^CLIENT_ID=//p' "$SS_IDP" | head -1)"
        d_secret="$(sed -n 's/^CLIENT_SECRET=//p' "$SS_IDP" | head -1)"
        d_csapp="$(sed -n 's/^CLOUDSYNC_APP_ID=//p' "$SS_IDP" | head -1)"
        echo "[i]  Bestehende Werte gefunden — Enter uebernimmt sie."
    fi

    local tenant="" client="" secret="" csapp=""
    if [ "$idp_type" = "m365" ]; then
        while :; do
            ss_ask "TENANT_ID (Verzeichnis-ID aus Schritt A2)" "$d_tenant"
            tenant="$SS_ANSWER"
            ss_valid_guid "$tenant" && break
            echo "     Das ist keine GUID (Muster: 8-4-4-4-12 Hex-Zeichen) — bitte pruefen (nicht die Objekt-ID!)."
        done
        while :; do
            ss_ask "CLIENT_ID (Anwendungs-ID aus Schritt A2)" "$d_client"
            client="$SS_ANSWER"
            ss_valid_guid "$client" && break
            echo "     Das ist keine GUID — bitte die 'Anwendungs-ID (Client)' kopieren."
        done
    else
        while :; do
            ss_ask "CLIENT_ID (aus Schritt B2)" "$d_client"
            client="$SS_ANSWER"
            [ -n "$client" ] || { echo "     Bitte die Client-ID angeben."; continue; }
            case "$client" in
                *.apps.googleusercontent.com) ;;
                *) echo "     Hinweis: Google-Client-IDs enden auf .apps.googleusercontent.com — bitte kurz pruefen." ;;
            esac
            break
        done
    fi

    while :; do
        if [ -n "$d_secret" ]; then
            printf 'CLIENT_SECRET (Eingabe unsichtbar; Enter = gespeicherten Wert behalten): '
        else
            printf 'CLIENT_SECRET (Eingabe bleibt unsichtbar): '
        fi
        IFS= read -rs secret || secret=""
        echo ""
        [ -z "$secret" ] && secret="$d_secret"
        [ -n "$secret" ] && break
        echo "     Das Secret darf nicht leer sein (Schritt A3 bzw. B2)."
    done

    if [ "$idp_type" = "m365" ]; then
        while :; do
            ss_ask "Optional: application_id der Cloud-Sync-App aus Schritt A6 (Enter = keine)" "$d_csapp"
            csapp="$SS_ANSWER"
            [ -z "$csapp" ] && break
            ss_valid_guid "$csapp" && break
            echo "     Das ist keine GUID — bitte die 'Anwendungs-ID (Client)' der Cloud-Sync-App kopieren."
        done
    fi

    # Login-Mail pro User
    local u mail lines=""
    if [ -n "$users" ]; then
        echo ""
        if [ "$idp_type" = "m365" ]; then
            echo "Jetzt die Anmelde-Adresse jedes Mitarbeiters — WICHTIG: den UPN"
            echo "(die Adresse, mit der er sich bei Microsoft anmeldet), KEINE Alias-Adresse."
        else
            echo "Jetzt die Google-Konto-E-Mail-Adresse jedes Mitarbeiters."
        fi
        local d_mail
        for u in $users; do
            d_mail=""
            [ -f "$SS_USERS_IDP" ] && d_mail="$(awk -v u="$u" '$1==u {print $2; exit}' "$SS_USERS_IDP")"
            while :; do
                ss_ask "Login-E-Mail fuer '${u}'" "$d_mail"
                mail="$SS_ANSWER"
                ss_valid_email "$mail" && break
                echo "     Das sieht nicht nach einer E-Mail-Adresse aus."
            done
            lines="${lines}${u} ${mail}
"
        done
    fi

    # Schreiben (root-only)
    mkdir -p "$SS_DIR"
    chmod 700 "$SS_DIR" 2>/dev/null || true
    umask 077
    {
        echo "IDP_TYPE=${idp_type}"
        [ -n "$tenant" ] && echo "TENANT_ID=${tenant}"
        echo "CLIENT_ID=${client}"
        echo "CLIENT_SECRET=${secret}"
        [ -n "$csapp" ] && echo "CLOUDSYNC_APP_ID=${csapp}"
    } > "$SS_IDP"
    chmod 600 "$SS_IDP"
    if [ -n "$lines" ]; then
        printf '%s' "$lines" > "$SS_USERS_IDP"
        chmod 600 "$SS_USERS_IDP"
    fi

    echo ""
    echo "[ok] Werte gespeichert — sie bleiben auf dieser VM (nur root kann sie lesen)."
    echo ""
    echo "Fertig! Gib deinem Mitarbyte-Ansprechpartner kurz Bescheid — dann geht's bei uns weiter."
}

# --- Modus: m365 (Anleitung Teil 5) ------------------------------------------

# $1 = Frage, $2 = Default (j|n) → rc 0 bei ja
ss_ask_yn() {
    local d="$2" hint
    [ "$d" = "j" ] && hint="J/n" || hint="j/N"
    while :; do
        printf '%s (%s): ' "$1" "$hint"
        IFS= read -r SS_ANSWER || SS_ANSWER=""
        case "$(printf '%s' "${SS_ANSWER:-$d}" | tr '[:upper:]' '[:lower:]')" in
            j|ja|y|yes) return 0 ;;
            n|nein|no)  return 1 ;;
        esac
        echo "     Bitte j oder n eingeben."
    done
}

# Wert aus einer KEY=VALUE-Datei (erste Fundstelle)
ss_env_get() {
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" | head -1
}

ss_m365() {
    local users=""
    if [ -f "$SS_REG" ]; then
        users="$(ss_json_get_users "$SS_REG")"
    elif [ -f "$SS_USERS_IDP" ]; then
        users="$(awk '{print $1}' "$SS_USERS_IDP" | tr '\n' ' ' | tr -s ' ')"
    fi
    if [ -z "$(printf '%s' "$users" | tr -d ' ')" ]; then
        echo ""
        echo "[i]  Keine Mitarbeiter-Liste auf dieser VM gefunden — eine kurze Frage vorab:"
        while :; do
            ss_ask "User-Namen wie im Registrierungs-Formular angegeben, durch Komma getrennt (z.B. max, erika)" ""
            users="$(printf '%s' "$SS_ANSWER" | tr ',' ' ' | tr -s ' ')"
            local ok=1 u
            [ -n "$(printf '%s' "$users" | tr -d ' ')" ] || ok=0
            for u in $users; do
                ss_valid_username "$u" || { echo "     '${u}' ist ungueltig (Kleinbuchstaben/Ziffern/Bindestrich, 2-31 Zeichen, beginnt mit Buchstabe)."; ok=0; }
            done
            [ "$ok" = 1 ] && break
        done
    fi

    echo ""
    echo "== Mitarbyte KI-OS — Outlook & SharePoint anbinden (Teil 5) =="
    echo "   Die Werte bleiben auf DIESER VM (root-only) — nichts davon wird gemailt."
    echo ""

    # Defaults: Re-Run aus m365.env, Tenant sonst aus Teil 3 (idp.env)
    local d_tenant d_client d_secret d_tools d_sites d_ro d_asst d_asst_users idp_client
    d_tenant="$(ss_env_get "$SS_M365" TENANT_ID)"
    d_client="$(ss_env_get "$SS_M365" CLIENT_ID)"
    d_secret="$(ss_env_get "$SS_M365" CLIENT_SECRET)"
    d_tools="$(ss_env_get "$SS_M365" TOOLS)"
    d_sites="$(ss_env_get "$SS_M365" SHAREPOINT_SITES)"
    d_ro="$(ss_env_get "$SS_M365" SHAREPOINT_READONLY)"
    d_asst="$(ss_env_get "$SS_M365" ASSISTANT_MAILBOX)"
    d_asst_users="$(ss_env_get "$SS_M365" ASSISTANT_USERS)"
    idp_client="$(ss_env_get "$SS_IDP" CLIENT_ID)"
    if [ -f "$SS_M365" ]; then
        echo "[i]  Bestehende Werte gefunden — Enter uebernimmt sie."
    elif [ -z "$d_tenant" ]; then
        d_tenant="$(ss_env_get "$SS_IDP" TENANT_ID)"
    fi

    local tenant client secret
    while :; do
        ss_ask "TENANT_ID (Verzeichnis-ID der App aus Teil 5)" "$d_tenant"
        tenant="$SS_ANSWER"
        ss_valid_guid "$tenant" && break
        echo "     Das ist keine GUID (Muster: 8-4-4-4-12 Hex-Zeichen) — bitte pruefen (nicht die Objekt-ID!)."
    done
    while :; do
        ss_ask "CLIENT_ID (Anwendungs-ID der App 'Mitarbyte KI-OS M365')" "$d_client"
        client="$SS_ANSWER"
        if ! ss_valid_guid "$client"; then
            echo "     Das ist keine GUID — bitte die 'Anwendungs-ID (Client)' kopieren."
            continue
        fi
        if [ -n "$idp_client" ] && [ "$client" = "$idp_client" ]; then
            echo "     ACHTUNG: Das ist die App aus Teil 3 (Firmen-Login). Fuer Outlook & SharePoint"
            echo "     gehoert eine EIGENE App her (Teil 5), sonst haengt der VM-Login daran."
            ss_ask_yn "     Trotzdem diese App verwenden?" n || continue
        fi
        break
    done
    while :; do
        if [ -n "$d_secret" ]; then
            printf 'CLIENT_SECRET (Eingabe unsichtbar; Enter = gespeicherten Wert behalten): '
        else
            printf 'CLIENT_SECRET (Eingabe bleibt unsichtbar): '
        fi
        IFS= read -rs secret || secret=""
        echo ""
        [ -z "$secret" ] && secret="$d_secret"
        [ -n "$secret" ] && break
        echo "     Das Secret darf nicht leer sein (Teil 5, CLIENT_SECRET erzeugen)."
    done

    local want_ol want_sp d_ol=j d_sp=j tools=""
    if [ -n "$d_tools" ]; then
        case ",$d_tools," in *,outlook,*) d_ol=j ;; *) d_ol=n ;; esac
        case ",$d_tools," in *,sharepoint,*) d_sp=j ;; *) d_sp=n ;; esac
    fi
    while :; do
        want_ol=0; want_sp=0
        ss_ask_yn "Outlook anbinden?" "$d_ol" && want_ol=1
        ss_ask_yn "SharePoint anbinden?" "$d_sp" && want_sp=1
        [ "$want_ol" = 1 ] || [ "$want_sp" = 1 ] && break
        echo "     Mindestens eines von beiden — sonst gibt es nichts anzubinden."
    done
    [ "$want_ol" = 1 ] && tools="outlook"
    [ "$want_sp" = 1 ] && tools="${tools:+${tools},}sharepoint"

    # SharePoint: Sites + nur lesen
    local sites="" readonly_v="" site bad
    if [ "$want_sp" = 1 ]; then
        echo ""
        while :; do
            ss_ask "SharePoint-Sites aus eurer Tabelle, durch Komma getrennt (https://<firma>.sharepoint.com/sites/<Name>)" "$d_sites"
            sites="$(printf '%s' "$SS_ANSWER" | tr -d ' ' | sed -e 's#/,#,#g' -e 's#/$##')"
            bad=0
            [ -n "$sites" ] || bad=1
            for site in $(printf '%s' "$sites" | tr ',' ' '); do
                ss_valid_sp_site "$site" || { echo "     '${site}' ist keine Site-Adresse (Muster: https://firma.sharepoint.com/sites/Name)."; bad=1; }
            done
            [ "$bad" = 0 ] && break
        done
        local d_ro_yn=j
        [ "$d_ro" = "false" ] && d_ro_yn=n
        if ss_ask_yn "Soll die KI dort nur lesen (keine Dateien anlegen/aendern)? Muss zur Freigabe im Graph Explorer passen" "$d_ro_yn"; then
            readonly_v=true
        else
            readonly_v=false
        fi
    fi

    # Outlook: geteilte Postfaecher je User + Assistenten-Postfach
    local mb_lines="" asst="" asst_users="" u d_mb mb list slug taken
    if [ "$want_ol" = 1 ]; then
        echo ""
        echo "Jetzt die GETEILTEN Postfaecher je Mitarbeiter (z.B. info@, service@) —"
        echo "Voraussetzung ist die Exchange-Freigabe (Vollzugriff + Senden als). Enter = keine."
        taken=" assistent $users "
        local slugmap=""   # "slug=upn " — ein Slug darf nur EIN Postfach meinen
        for u in $users; do
            d_mb=""
            [ -f "$SS_MAILBOXES_M365" ] && d_mb="$(awk -v u="$u" '$1==u {printf "%s%s", sep, $2; sep=","}' "$SS_MAILBOXES_M365")"
            while :; do
                ss_ask "Geteilte Postfaecher fuer '${u}'" "$d_mb"
                list="$(printf '%s' "$SS_ANSWER" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
                case "$list" in -|keine) list="" ;; esac
                bad=0
                local ulines="" umap="$slugmap"
                for mb in $(printf '%s' "$list" | tr ',' ' '); do
                    if ! ss_valid_email "$mb"; then
                        echo "     '${mb}' sieht nicht nach einer E-Mail-Adresse aus."; bad=1; continue
                    fi
                    slug="$(ss_mailbox_slug "$mb")"
                    case "$taken" in *" ${slug} "*)
                        echo "     '${mb}' ergibt den Kurznamen '${slug}' — der ist schon ein Mitarbeiter-Name oder reserviert."; bad=1; continue ;;
                    esac
                    case " $umap " in
                        *" ${slug}=${mb} "*) ;;
                        *" ${slug}="*) echo "     '${mb}' kollidiert mit einem anderen Postfach mit Kurznamen '${slug}'."; bad=1; continue ;;
                        *) umap="${umap} ${slug}=${mb}" ;;
                    esac
                    ulines="${ulines}${u} ${mb}
"
                done
                if [ "$bad" = 0 ]; then
                    mb_lines="${mb_lines}${ulines}"
                    slugmap="$umap"
                    break
                fi
            done
        done

        echo ""
        echo "Optional: ein ASSISTENTEN-Postfach — die eigene Adresse der KI (z.B. ki-os@firma.de),"
        echo "ein Konto mit eigener Anmeldung."
        while :; do
            ss_ask "Adresse des Assistenten-Postfachs (Enter = keins)" "$d_asst"
            asst="$(printf '%s' "$SS_ANSWER" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
            case "$asst" in -|keins) asst="" ;; esac
            [ -z "$asst" ] && break
            ss_valid_email "$asst" && break
            echo "     Das sieht nicht nach einer E-Mail-Adresse aus."
        done
        if [ -n "$asst" ]; then
            while :; do
                ss_ask "Welche Mitarbeiter nutzen es? Komma-getrennt (Enter = alle)" "$d_asst_users"
                asst_users="$(printf '%s' "$SS_ANSWER" | tr -d ' ')"
                bad=0
                for u in $(printf '%s' "$asst_users" | tr ',' ' '); do
                    case " $users " in *" $u "*) ;; *) echo "     '${u}' ist kein Mitarbeiter dieser VM (${users})."; bad=1 ;; esac
                done
                [ "$bad" = 0 ] && break
            done
        fi
    fi

    # Schreiben (root-only)
    mkdir -p "$SS_DIR"
    chmod 700 "$SS_DIR" 2>/dev/null || true
    umask 077
    {
        echo "TENANT_ID=${tenant}"
        echo "CLIENT_ID=${client}"
        echo "CLIENT_SECRET=${secret}"
        echo "TOOLS=${tools}"
        [ -n "$sites" ] && echo "SHAREPOINT_SITES=${sites}"
        [ -n "$readonly_v" ] && echo "SHAREPOINT_READONLY=${readonly_v}"
        [ -n "$asst" ] && echo "ASSISTANT_MAILBOX=${asst}"
        [ -n "$asst" ] && echo "ASSISTANT_USERS=${asst_users}"
    } > "$SS_M365"
    chmod 600 "$SS_M365"
    printf '%s' "$mb_lines" > "$SS_MAILBOXES_M365"
    chmod 600 "$SS_MAILBOXES_M365"

    echo ""
    echo "[ok] Werte gespeichert — sie bleiben auf dieser VM (nur root kann sie lesen)."
    if [ "$want_ol" = 1 ]; then
        echo "     Outlook: jeder Mitarbeiter sagt nach der Einrichtung seinem Assistenten"
        echo "     \"Melde mich bei Outlook an\" (Teil 4) — nacheinander, nicht gleichzeitig."
    fi
    echo ""
    echo "Fertig! Gib deinem Mitarbyte-Ansprechpartner kurz Bescheid — dann geht's bei uns weiter."
}

# --- Modus: revoke -----------------------------------------------------------

ss_revoke() {
    local before=0 after=0
    if [ -f "$SS_AUTH_KEYS" ]; then
        before="$(grep -c . "$SS_AUTH_KEYS" || true)"
        grep -v '@mitarbyte\.com' "$SS_AUTH_KEYS" > "${SS_AUTH_KEYS}.tmp" || true
        mv "${SS_AUTH_KEYS}.tmp" "$SS_AUTH_KEYS"
        chmod 600 "$SS_AUTH_KEYS"
        after="$(grep -c . "$SS_AUTH_KEYS" || true)"
    fi
    if [ -f "$SS_ADMIN_KEYS" ]; then
        : > "$SS_ADMIN_KEYS"
    fi
    echo "[ok] Mitarbyte-Zugang entfernt ($((before-after)) Key(s) aus authorized_keys, verwaltete Key-Datei geleert)."
    echo "     Wieder aktivieren: bash /root/mitarbyte.sh   (Registrierung erneut ausfuehren)"
    echo "     Ganz sicher gehen: hPanel → VPS → Betriebssystem neu installieren."
}

# --- Entry -------------------------------------------------------------------

ss_usage() {
    echo "Nutzung: bash /root/mitarbyte.sh [register|idp|m365|revoke]" >&2
}

main() {
    local mode="${1:-register}"
    case "$mode" in register|idp|m365|revoke) ;; *) ss_usage; exit 1 ;; esac
    ss_init_paths

    if [ -z "${SELFSERVICE_PREFIX:-}" ] && [ "$(id -u)" != "0" ]; then
        ss_die "Bitte als root ausfuehren (im Hostinger-Browser-Terminal als 'root' anmelden)."
    fi

    if [ "$mode" = "register" ]; then
        local osdesc
        if ! osdesc="$(ss_os_check)"; then
            echo "FEHLER: Diese VM laeuft '${osdesc}' — unterstuetzt sind Ubuntu 22.04 und 24.04 LTS." >&2
            echo "" >&2
            echo "So beheben: hPanel → VPS → Betriebssystem → 'Ubuntu 24.04 LTS' (Kategorie" >&2
            echo "'Betriebssystem ohne Panel') neu installieren, danach diesen Befehl erneut" >&2
            echo "ausfuehren. Achtung: Neuinstallation loescht alle Daten auf der VM." >&2
            exit 1
        fi
    fi

    case "$mode" in
        register) ss_register ;;
        idp)      ss_idp ;;
        m365)     ss_m365 ;;
        revoke)   ss_revoke ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
