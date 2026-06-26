#!/usr/bin/env bash
# user-onboarding-Installer — kopiert den Skill nach ~/.claude/skills/.
# Laedt in Desktop-App, Web und Terminal. Kein GitHub-Login noetig.
#   curl -fsSL https://raw.githubusercontent.com/Mitarbyte/marketplace/main/install.sh | bash
set -euo pipefail
REPO_TGZ="https://github.com/Mitarbyte/marketplace/archive/refs/heads/main.tar.gz"
SKILL_SUBPATH="marketplace-main/plugins/user-onboarding/skills/user-onboarding"
DEST="${HOME}/.claude/skills/user-onboarding"

command -v curl >/dev/null 2>&1 || { echo "curl wird benoetigt." >&2; exit 1; }
command -v tar  >/dev/null 2>&1 || { echo "tar wird benoetigt." >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "› Lade user-onboarding-Skill …"
curl -fsSL "$REPO_TGZ" -o "$TMP/m.tgz"
tar -xzf "$TMP/m.tgz" -C "$TMP"
[ -f "$TMP/$SKILL_SUBPATH/SKILL.md" ] || { echo "Skill im Archiv nicht gefunden." >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -R "$TMP/$SKILL_SUBPATH" "$DEST"

echo "✓ Installiert nach $DEST"
echo "  Jetzt Claude Code starten (Desktop-App oder 'claude') und /user-onboarding aufrufen."
