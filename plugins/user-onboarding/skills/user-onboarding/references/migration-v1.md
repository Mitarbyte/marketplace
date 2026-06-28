# Migration vom v1-Setup (Chrome-Bridge + vm-oauth + SSHFS)

Detail-Anleitung fuer Schritt 12 aus `SKILL.md`. Nur relevant fuer
Bestands-User, die schon nach dem alten Muster onboardet wurden.

`ki-os-vm` ist der feste SSH-Alias (vom Skill gesetzt, keine Auswahl).

## Was wegfaellt und warum

| v1-Komponente | Ersatz in v2 |
|---|---|
| Chrome-Bridge (lokaler Chrome + `RemoteForward 9222`) | Headed Chrome laeuft auf der VM, sichtbar per noVNC (`http://localhost:6080/vnc.html?resize=scale`) |
| `vm-oauth` (+ ControlMaster/`-mux`-Alias) | OAuth-CLIs laufen auf der VM (`ki-os-auth ...`), Browser erscheint im noVNC-Tab |
| SSHFS-Mount (FUSE-T / sshfs / WinFsp+sshfs-win) | Mutagen-Sync nach `~/KI-OS` |
| Cockpit-Tunnel auf lokal `13847` | Cockpit-Tunnel auf lokal `3847` (vereinheitlicht) |

> **Wichtig fuer den User:** Die Browser-Logins lebten bisher im lokalen
> Bridge-Chrome-Profil. Nach der Migration muessen sie **einmalig neu**
> im VM-Chrome gemacht werden — `http://localhost:6080/vnc.html?resize=scale` oeffnen
> und in die Zielsysteme (Google, GitHub, CRM, ...) einloggen.

## macOS

```bash
UID_GUI=$(id -u)
MAC_USER=$(whoami)

# 1. Alte LaunchAgents stoppen + entfernen (Labels enthalten den Alias)
for la in ~/Library/LaunchAgents/com.${MAC_USER}.mac-chrome-bridge.*.plist \
          ~/Library/LaunchAgents/com.${MAC_USER}.sshfs.*.plist; do
    [ -f "$la" ] || continue
    label=$(basename "$la" .plist)
    launchctl bootout gui/${UID_GUI}/${label} 2>/dev/null || true
    rm "$la"
    echo "entfernt: $la"
done

# Alter Cockpit-Tunnel (Port 13847): NICHT loeschen, sondern in Schritt 8
# durch die neue 3847-Fassung ueberschreiben lassen (gleiches Label).
# Falls der Alias gewechselt hat, den alten auch entfernen:
#   launchctl bootout gui/${UID_GUI}/com.${MAC_USER}.ssh-tunnel.<alt>-cockpit
#   rm ~/Library/LaunchAgents/com.${MAC_USER}.ssh-tunnel.<alt>-cockpit.plist

# 2. SSHFS-Mount unmounten + Mountpoint entfernen.
#    Der Mountpoint heisst NICHT zwingend wie der Alias (real gesehen:
#    ~/Desktop/mitarbyte) — aktive Mounts dynamisch ermitteln. FUSE-T-
#    Mounts erscheinen als Typ nfs mit Quelle "fuse-t:/...".
#    Hinweis: lief sshfs mit -f als Kind des LaunchAgents, verschwindet
#    der Mount meist schon mit dem bootout aus Schritt 1.
mount | awk '$1 ~ /^fuse-t:|sshfs/ {print $3}' | while read -r mp; do
    umount "$mp" 2>/dev/null || diskutil unmount force "$mp" 2>/dev/null || true
    rmdir "$mp" 2>/dev/null && echo "entfernt: $mp"
done
# Falls der Mount schon weg ist, den leeren Mountpoint-Ordner trotzdem
# aufraeumen (Pfad steht in den ProgramArguments der sshfs-Plist):
rmdir ~/Desktop/ki-os-vm 2>/dev/null || true

# 2b. Logs der alten Agents aufraeumen
rm -f ~/Library/Logs/sshfs-*.log ~/Library/Logs/sshfs-*.err.log \
      ~/Library/Logs/mac-chrome-bridge*.log

# 3. Helper loeschen (inkl. evtl. .bak-Kopien aus frueheren Updates)
rm -f ~/.local/bin/vm-oauth* ~/.local/bin/mac-chrome-bridge*

# 4. Optional: altes Bridge-Chrome-Profil loeschen (Logins sind dann weg —
#    die muessen sowieso neu in den VM-Chrome)
rm -rf ~/.chrome-ki-os-vm
```

FUSE-T/sshfs selbst koennen installiert bleiben (stoeren nicht) oder per
`brew uninstall --cask fuse-t fuse-t-sshfs` entfernt werden.

## Linux

```bash
# 1. Alte systemd-User-Services stoppen + entfernen
for unit in chrome-bridge.service ki-os-vm-sshfs.service sshfs-ki-os-vm.service; do
    systemctl --user disable --now "$unit" 2>/dev/null || true
    rm -f ~/.config/systemd/user/"$unit"
done
systemctl --user daemon-reload

# Alter Cockpit-Tunnel (13847) hat denselben Unit-Namen wie der neue —
# wird in Schritt 8 ueberschrieben, nichts zu tun.

# 2. SSHFS-Mount unmounten + Mountpoint entfernen
fusermount -u ~/ki-os-vm 2>/dev/null || true
rmdir ~/ki-os-vm 2>/dev/null || true

# 3. Helper loeschen
rm -f ~/.local/bin/vm-oauth

# 4. Optional: altes Bridge-Chrome-Profil loeschen
rm -rf ~/.chrome-ki-os-vm
```

## Windows (nativ)

```powershell
# 1. Alte Scheduled Tasks stoppen + entfernen
foreach ($t in @("ki-os-vm-chrome-bridge", "sshfs-ki-os-vm")) {
    Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
}
# Alter Cockpit-Tunnel-Task (13847) hat denselben Namen wie der neue —
# wird in Schritt 8 per Unregister/Register ueberschrieben, nichts zu tun.

# Auch evtl. Startup-Shortcuts entfernen:
Remove-Item "$([Environment]::GetFolderPath('Startup'))\ki-os-vm-chrome-bridge.lnk" -ErrorAction SilentlyContinue

# 2. sshfs-win-Laufwerk trennen
net use Z: /delete 2>$null

# 3. Helper loeschen
$bin = "$env:USERPROFILE\.local\bin"
Remove-Item "$bin\vm-oauth", "$bin\vm-oauth.ps1", "$bin\win-chrome-bridge.ps1", "$bin\win-sshfs-mount.ps1" -ErrorAction SilentlyContinue

# 4. Optional: altes Bridge-Chrome-Profil loeschen
Remove-Item -Recurse -Force "$env:USERPROFILE\.chrome-ki-os-vm" -ErrorAction SilentlyContinue
```

WinFsp/sshfs-win koennen deinstalliert werden (`winget uninstall WinFsp.WinFsp
SSHFS-Win.SSHFS-Win`) — optional. Die frueher erzwungene
Git-`usr\bin`-PATH-Priorisierung darf rueckgebaut werden (Eintrag
`C:\Program Files\Git\usr\bin` aus dem User-PATH entfernen) — noetig ist
sie nicht mehr.

## Alle Plattformen: ~/.ssh/config bereinigen

Der `Host ki-os-vm`-Block wird auf die minimale v2-Fassung reduziert
(passiert normalerweise schon in Schritt 4 von `SKILL.md`). Zu entfernen:

- `RemoteForward ...` (Chrome-Bridge)
- `LocalForward ...` (Cockpit — Tunnel laufen jetzt als Autostart-Prozesse)
- `ControlMaster` / `ControlPath` / `ControlPersist`
- der komplette `Host ki-os-vm-mux`-Block (Windows-Zwei-Alias-Konstrukt)

Pruefen:

```bash
grep -nE 'RemoteForward|LocalForward|ControlMaster|ControlPath|ControlPersist|-mux' ~/.ssh/config
# erwartet: keine Treffer (zumindest nicht im ki-os-vm-Block)
```

## VM-seitig: obsoleten CHROME_BRIDGE_PORT-Export entfernen

Das v1-Onboarding hat eine Export-Zeile oben in die `~/.bashrc` auf der
VM geschrieben. Aufraeumen (idempotent):

```bash
ssh ki-os-vm 'sed -i.bak "/^# mitarbyte: Chrome-Bridge-Port/d;/^export CHROME_BRIDGE_PORT=/d" ~/.bashrc && echo OK'
```

## Verifikation nach der Migration

```bash
# Keine v1-Reste mehr aktiv:
# macOS:
launchctl list | grep -E 'chrome-bridge|sshfs' || echo "sauber"
# Linux:
systemctl --user list-units | grep -E 'chrome-bridge|sshfs' || echo "sauber"
```

```powershell
# Windows:
Get-ScheduledTask | Where-Object { $_.TaskName -match 'chrome-bridge|sshfs' }
# erwartet: leer
```

Danach mit Schritt 13 (`SKILL.md`) abschliessen. Erinnerung an den User:
einmaliger Re-Login in die Zielsysteme im VM-Chrome (noVNC-Tab).
