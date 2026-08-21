# Mutagen-Sync — Hintergrund, Konflikt-Semantik, Troubleshooting

Den Pflicht-Autostart richtet `scripts/setup-mutagen.sh` (macOS/Linux) bzw.
`scripts/setup-mutagen.ps1` (Windows) ein — dieses Dokument erklärt das
**Warum** hinter Session-Konfiguration und Ignores.

## Wozu

Mutagen synchronisiert den VM-Workspace `/home/<VM_USER>/KI-OS` beidseitig in
den lokalen Ordner `~/KI-OS` (Windows: `%USERPROFILE%\KI-OS`):

- **Echte lokale Kopie** statt Netz-Mount — friert bei Verbindungsabbruch
  nicht ein, voller Speed beim Öffnen, offline lesbar
- **Reconnectet selbst** nach Schlaf/Netzwechsel (eigener Daemon)
- **Two-way:** lokale Edits gehen zur VM zurück, VM-Änderungen
  (Agent-Outputs) erscheinen lokal

Transport ist die bestehende SSH-Verbindung (`ki-os-vm`-Alias aus
`~/.ssh/config`) — kein extra Dienst, kein extra Account.

> **Keepalives:** Mutagen setzt für seinen **eigenen** Agent-Transport eigene
> Werte auf der Kommandozeile (`-oConnectTimeout=5 -oServerAliveInterval=10
> -oServerAliveCountMax=1`) und **überstimmt damit den `ServerAliveInterval`
> aus der `~/.ssh/config`**. Die `ServerAliveInterval 15` im Alias wirken auf
> die **Tunnel** (`references/tunnels.md`), nicht auf Mutagen. Ein hängender
> Sync ist deshalb **nie** mit „die ssh-config hat die falschen Keepalives"
> erklärt — dort zuerst den Transport-Binary prüfen (nächster Abschnitt).

### Windows: Mutagen muss den nativen OpenSSH benutzen

Mutagen sucht sich sein `ssh` **selbst** und bevorzugt auf Windows die
**Git-for-Windows-MSYS2-ssh** (`C:\Program Files\Git\usr\bin\ssh.exe`) — auch
dann, wenn die **nicht** im `PATH` steht und `C:\Windows\System32\OpenSSH`
davor liegt. Prüfen, welches Binary der Transport wirklich fährt:

```powershell
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" |
    Where-Object { $_.CommandLine -match 'mutagen-agent' } |
    Select-Object ProcessId, CommandLine
```

Steht dort `Git\usr\bin\ssh.exe`, ist der Transport auf der fragilen
MSYS2-Pipe-Emulation: der `mutagen-agent` auf der VM stirbt, lokal bleibt die
Session in `Applying changes` stehen, `mutagen sync pause` **antwortet nicht
mehr** (Daemon-Goroutine blockiert) und VM-seitig hängt eine `<user>@notty`-
sshd-Session **ohne** Agent-Child. Fix — Suchpfad voranstellen:

```powershell
[Environment]::SetEnvironmentVariable('MUTAGEN_SSH_PATH','C:\Windows\System32\OpenSSH','User')
```

`setup-mutagen.ps1` setzt das persistent (User-Scope), und der von
`setup-tunnels.ps1` generierte Watchdog-Guard setzt es **im Guard-Prozess**,
bevor er den Daemon startet — sonst erbt der Daemon die Variable nicht.

## Daemon-Autostart pro OS

| OS | Mechanismus |
|----|-------------|
| macOS | `mutagen daemon register` (offizielle launchd-Integration) |
| Linux | systemd-User-Service `mutagen-daemon.service` (+ Linger); `daemon register` unterstützt Linux nicht |
| Windows | der gemeinsame Scheduled Task `ki-os-vm-watchdog`: sein 2-Min-Guard startet den Daemon unsichtbar (`wscript.exe`-Launcher, Fensterstil 0 — sonst poppt bei jedem Login ein Konsolenfenster mit Daemon-Logs auf), sobald mutagen installiert ist und kein `mutagen`-Prozess läuft. Angelegt von `setup-tunnels.ps1` (Schritt 7, volle Fassung mit Tunneln) — fehlt er noch, legt `setup-mutagen.ps1` ihn selbst **additiv Mutagen-only** an (`setup-tunnels.ps1 -EnsureMutagen`, räumt nichts ab); ein späterer Schritt-7-Lauf erweitert denselben Task um die Tunnel |

> **Windows-Detail:** Beim Daemon prüft der Watchdog-Guard `Get-Process
> mutagen`; zusätzlich ist der **Daemon-Lock** der Backstop — `mutagen daemon
> run` bricht beim Doppelstart ab, *bevor* eine SSH-Verbindung aufgebaut
> wird, selbst ein blinder Respawn wäre hier leak-frei. Die Tunnel haben
> keinen solchen Lock und brauchen zwingend den expliziten Port-Listen-Check
> (`references/tunnels.md`). Beide Guards NICHT vermischen.

## Selbstheilung — Session-Watchdog

Der Daemon-Autostart hält nur den **Daemon-Prozess** am Leben. Mutagen
reconnectet die Session zwar selbst nach transienten Transport-Abrissen
(Schlaf/Netzwechsel) — **aber** eine Session, die nach langem **VM-Idle-Suspend**
in `Paused`/`Halted` landet, kommt **nicht** von allein zurück. VM-seitig
erscheint dann ein toter `mutagen-agent`, und lokale Skill-Outputs kommen nicht
mehr im Obsidian-Vault an, obwohl die VM-Seite gesund ist.

Deshalb läuft zusätzlich ein kleiner **Session-Watchdog** (~alle 2 min):

| OS | Mechanismus |
|----|-------------|
| macOS | LaunchAgent `com.<user>.ki-os-vm.mutagen-watchdog` (`StartInterval 120`) → `scripts/ki-os-mutagen-watchdog.sh` (aus `~/.local/bin/`) |
| Linux | systemd-User-Timer `ki-os-mutagen-watchdog.timer` (`OnUnitActiveSec=2min`) + oneshot-Service, ruft denselben Guard |
| Windows | im gemeinsamen `ki-os-vm-watchdog`-Task mit abgedeckt (2-Min-Tick resumt zusätzlich die Session) |

Der Guard ist idempotent: Steht die Session auf `Watching for changes`, tut er
nichts; jeder andere Zustand → `mutagen sync resume ki-os` (no-op auf laufender
Session, heilt aber `paused`/`halted`). Fehlt die Session ganz, greift der
Watchdog **nicht** (Neuanlegen braucht den VM-Pfad) → dann `/user-onboarding`
erneut laufen lassen. Manuell prüfen: `mutagen sync list ki-os` ·
Guard-Logs (macOS) `~/Library/Logs/ki-os-mutagen-watchdog*.log` ·
(Linux) `journalctl --user -u ki-os-mutagen-watchdog`.

> **Grenze des Watchdogs — nicht überschätzen.** `sync resume` heilt **nur**
> `paused`/`halted`. Die zwei häufigsten Dauerzustände heilt er **nicht**:
>
> | Zustand | Ursache | Was wirklich hilft |
> |---|---|---|
> | `Applying changes` + `Transition problems: N` | Symlinks ohne Developer Mode (s.o.) | `--symlink-mode=ignore` (Session neu anlegen) |
> | `Applying changes`, Daemon-CPU bewegt sich nicht, `sync pause` hängt | toter Agent-Transport (meist Git-Bash-ssh) | `MUTAGEN_SSH_PATH` + Daemon-Hard-Restart (Recovery unten) |
>
> In beiden Fällen läuft der Guard alle 2 min ins Leere: Er ruft `resume` auf
> einer nicht-pausierten Session — ein No-op. Ein Watchdog-Task, der „läuft",
> ist deshalb **kein** Beweis, dass der Sync gesund ist. Gesund heißt
> ausschließlich: Status `Watching for changes` **ohne** Problems-Block.

### macOS-TCC: warum der Watchdog eine eigene Shell braucht

Der Skill legt den lokalen Sync-Ordner nach `~/KI-OS`. **Bestands-Setups** haben
ihn oft woanders — typisch `~/Desktop/KI-OS`. Und `~/Desktop`, `~/Documents`,
`~/Downloads` sind von macOS per **TCC** geschützt. Für einen LaunchAgent, der
über `/bin/bash` läuft, heißt das:

| Operation im geschützten Ordner | Ergebnis über `/bin/bash` |
|---|---|
| `stat` / `[ -e ]` | OK |
| `mkdir` (selbst erzeugt) | OK |
| `opendir` / `ls` | `Operation not permitted` |
| `rename` fremd erzeugter Objekte (`mv`) | `Operation not permitted` |

Genau das trifft die Auflösung blockierter VM-Löschungen (unten): Der Watchdog
kommt bis zum `mv` und scheitert dort. Eine TCC-Freigabe für `/bin/bash` würde
das lösen — aber damit hätte **jedes** bash-Skript auf dem Rechner Zugriff auf
Desktop, Dokumente und Downloads.

Deshalb läuft der Watchdog über eine **eigene Shell-Kopie**
`~/.local/bin/ki-os-watchdog-shell`, die `setup-mutagen.sh` anlegt:

```bash
cp /bin/bash ~/.local/bin/ki-os-watchdog-shell
codesign --force --sign - ~/.local/bin/ki-os-watchdog-shell   # PFLICHT
```

- Das **Ad-hoc-Signieren ist nicht optional**: `/bin/bash` ist ein
  Apple-Platform-Binary, dessen Signatur nur am Originalpfad validiert. Eine
  unsignierte Kopie killt der Kernel beim Start sofort (`Killed: 9`).
- Mit der signierten Kopie gehen `opendir` **und** `rename` in
  `~/Desktop/KI-OS` durch — verifiziert sowohl bei `launchctl bootstrap` als
  auch bei Timer-Start durch launchd, **ohne** jede TCC-Freigabe. Ein
  Platform-Binary bekommt im Agent-Kontext keine Attribution und damit hartes
  Deny; die eigene Binary hat eine eigene Identität.
- Die Kopie wird bei einem Re-Run **nicht** ersetzt, solange sie läuft: ein
  neues Binary am selben Pfad invalidiert einen ggf. erteilten TCC-Grant.
- Scheitert es trotzdem mit EPERM, meldet das Setup `TCC_GRANT_NEEDED` und
  leitet die Freigabe an (Systemeinstellungen → Datenschutz & Sicherheit →
  Festplattenvollzugriff → die **Watchdog-Shell**, nicht `/bin/bash`).
  Dauerhafte Alternative: Sync-Ordner nach `~/KI-OS` umziehen.

Gewarnt wird **nur bei nachgewiesenem** EPERM (Marker aus dem letzten
Watchdog-Lauf), nicht vorsorglich anhand des Ordnerpfads — ein
Systemeinstellungs-Eingriff auf Verdacht ist keine Diagnose.

## Session-Konfiguration

**Endpoint-Reihenfolge ist bewusst:** Die VM ist **Alpha** (erstes Argument),
der lokale Ordner ist **Beta**. Im Modus `two-way-resolved` gewinnt bei echten
Konflikten automatisch Alpha — also die VM, auf der der Agent arbeitet.

### Shared-Group (nur bei geteiltem `Workspaces`-Bind-Mount)

> **Das gilt nur für VMs, auf denen Mitarbeiter ihren `Workspaces`-Ordner
> wirklich teilen** (Stand 2026-07-29: hvotto). Auf allen anderen VMs — auch
> Multi-User-VMs ohne Sharing — wird **keine** Gruppen-Freigabe gesetzt. Die
> Skripte **erkennen** das VM-seitig am setgid-Bit (unten), es muss niemand
> etwas mitgeben oder wissen.

`~/KI-OS/Workspaces` ist auf einer solchen VM **kein normaler Ordner**, sondern
ein **Bind-Mount**, der von mehreren Mitarbeitern geteilt wird — er zeigt bei
allen auf dieselbe Quelle:

```
/home/<VM_USER>/KI-OS/Workspaces  ->  /home/<OWNER>/KI-OS/Workspaces
```

Die geteilten Verzeichnisse sind `drwxrws---` (setgid, Modus `2770`) mit der
geteilten Gruppe (auf hvotto `mitarbyte`); jeder beteiligte Mitarbeiter ist in
dieser Gruppe. Dateien, die **Mutagen** dort VM-seitig anlegt, würden mit den
Default-Modes `0600`/`0700` und der *primären* Gruppe des Users entstehen — die
anderen Mitarbeiter könnten sie dann **nicht mehr lesen oder schreiben**, und
deren Agents laufen in Permission-Fehler. Deshalb setzen `setup-mutagen.sh`/`.ps1`
auf **alpha** (der VM):

| Flag | Wert | Wirkung |
|---|---|---|
| `--default-group-alpha` | erkannte Gruppe | neue Dateien/Ordner gehören der geteilten Gruppe |
| `--default-file-mode-alpha` | `0660` | Gruppe darf lesen **und** schreiben |
| `--default-directory-mode-alpha` | `0770` | Gruppe darf betreten + anlegen |

Nur `-alpha`: auf einer Windows-/macOS-**beta** sind POSIX-Modes bedeutungslos
bzw. unerwünscht.

**Wie erkannt wird (kein Default, keine Rückfrage).** Das setgid-Bit *ist* das
Kennzeichen des geteilten Ordners — die Skripte fragen es einmal per SSH ab:

```sh
find $HOME/KI-OS/Workspaces -maxdepth 0 -perm -2000 -printf %g
```

| Ergebnis | Bedeutung | Folge |
|---|---|---|
| Gruppenname (Exit 0) | geteilter Bind-Mount | Gruppe + `0660`/`0770` auf alpha |
| leer (Exit 0) | Ordner da, aber nicht setgid | keine Gruppen-Freigabe |
| Exit 1 | kein `Workspaces`-Ordner (Normalfall) | keine Gruppen-Freigabe |
| Exit 255 | SSH nicht erreichbar | keine Freigabe **+ laute WARN** |

Damit bekommt eine Single-User- oder eine Multi-User-VM **ohne** Sharing nie
eine Gruppen-Freigabe, und auf einer Sharing-VM stimmt die Gruppe automatisch —
auch wenn sie dort nicht `mitarbyte` heißt. Überstimmen geht per
`--shared-group <NAME>` bzw. `-SharedGroup <NAME>`; `''` erzwingt aus.

**Warum das setgid-Bit allein nicht reicht** (sonst wäre
`--default-group-alpha` redundant): Mutagen legt Dateien **nicht** direkt im
Ziel-Verzeichnis an, sondern staged sie unter `~/.mutagen/staging`
(`Stage mode: Mutagen Data Directory`) und **renamed** sie dann an ihren Platz.
setgid-Gruppenvererbung greift aber nur beim *Anlegen* in einem Verzeichnis,
nicht beim Rename hinein — die Datei behält die primäre Gruppe des Users.
Deshalb muss die Gruppe explizit gesetzt werden.

> **Reichweite der Modes — und was sie *nicht* öffnet** (nur relevant, wenn
> oben eine Gruppe erkannt wurde): Die Modes gelten für
> **alles**, was Mutagen auf der VM neu anlegt, nicht nur für `Workspaces/` —
> `~/KI-OS/.env` (heute `0600`) wird beim nächsten Sync-Schreibvorgang zu
> `0660` mit Gruppe `mitarbyte`. **Erreichbar** wird die Datei damit für andere
> Mitarbeiter trotzdem nicht: Home-Verzeichnisse sind `drwxr-x---` (Gruppe =
> eigene User-Gruppe), fremde User können `/home/<user>` gar nicht betreten.
> Wirksam wird die Gruppen-Freigabe genau dort, wo der Pfad bewusst geöffnet
> ist — im ACL-freigegebenen `Workspaces`-Bind-Mount. Zwei Konsequenzen:
> (1) Wer Secrets im Workspace hat, legt sie **nicht** unter `Workspaces/` ab
> (oder nimmt sie in die Ignores — auf dem Laptop haben sie ohnehin nichts zu
> suchen). (2) Wird ein Home-Verzeichnis später geöffnet (`chmod o+x`, ACL),
> sind diese Dateien gruppen-**schreibbar** — dann vorher `--shared-group ''`
> setzen und die Session neu anlegen.

**Warum diese Ignores (Pflicht, nicht kürzen):**

| Ignore | Grund |
|--------|-------|
| `--ignore-vcs` (`.git`) | Git-Metadaten gehören VM-seitig — deckt das `.git` des Hub-Klons unter `hub/` ab. Lokal liegt nur der lesbare Arbeitsstand |
| `node_modules`, `.venv`, `__pycache__` | Abhängigkeits-/Build-Verzeichnisse — groß, maschinenspezifisch, auf der VM gebaut |
| `.obsidian/workspace*` | Obsidian-Fenster-Layout ist gerätespezifisch — würde sonst zwischen VM/Laptop hin- und herflattern |
| `.cache`, `dist`, `.next` | Build-/Browser-Caches |
| `.DS_Store` | macOS-Finder-Artefakte nicht auf die VM tragen |
| `/Ablage`, `/SharePoint`, `/Sharepoint`, `/Google Drive` | Gehören dem VM-seitigen **Cloud-Sync** (Cloud-Client gegen eine SharePoint-Bibliothek bzw. ein Google Shared Drive). Ohne diese Ignores hängen an denselben Bytes **drei** Sync-Engines mit zwei unabhängigen Konfliktmodellen: Mutagen (VM↔Client), der Cloud-Client (VM↔Cloud) und der Cloud-Client der Kollegen an derselben Bibliothek — eine lokale Änderung liefe Client → Mutagen → VM → Cloud-Client → Cloud → Kollegen-Client. Der Ordner ist über die Cloud ohnehin auf jedem Arbeitsplatz verfügbar (Explorer/Web/Mobile), eine zweite Kopie über Mutagen bringt nichts und erzeugt Konfliktkopien. **Root-verankert** (führender `/`), damit nicht zufällig gleichnamige Unterordner tiefer im Baum mit ausgeschlossen werden. Gilt auf jeder VM, unabhängig davon ob der Cloud-Sync dort aktiv ist (No-op ohne den Ordner). Die Namen sind fleet-weite Konvention (Literale im Skript) und bewusst umlautfrei — macOS legt Dateinamen zerlegt (NFD) ab, Linux zusammengesetzt (NFC), ein Ignore mit `ä` kann auf einer Seite nicht matchen, und ein nicht greifender Ignore fällt erst durch Konfliktkopien auf. **Warum vier:** `Ablage` ist die aktuelle, providerneutrale Konvention; `SharePoint` ist Bestand (schleumer, live seit 2026-08-07, wird bewusst nicht migriert); `Sharepoint` ist dieselbe Schreibweise mit kleinem `p`, real vergeben — **Mutagen-Ignores sind case-sensitiv**, `/SharePoint` trifft `Sharepoint` also nicht (aufgefallen 2026-08-12: der Ordner lief unbemerkt doppelt); `Google Drive` ist der Name, den Google Drive for Desktop selbst vergibt. Ein zusätzliches Literal kostet nichts und spart ein Migrationsfenster am Live-Sync. Dass der Ordner überhaupt *im* Sync-Baum liegt, ist entschieden, nicht zufällig: außerhalb bräuchte es diesen Ignore nicht, aber der Ordner wäre dann nicht im lokalen Vault — die Abwägung steht in `docs/features/cloud-sync/` |
| `/Geteilte-Arbeitsplaetze`, `/Meine-Arbeitsplaetze`, `/dev`, `/<COMPANY_LOCAL>` | Drei-Ordner-Struktur des **cloud-Hub-Backends** (`docs/features/cloud-sync/hub-abloesung.md`). Auf reinen cloud-Usern entfällt Mutagen ganz (der Skill überspringt Schritt 8); diese Ignores sind das **Übergangsnetz** für VMs mit gemischten Backends bzw. noch laufende Bestands-Sessions — die Cloud-Ordner (`/<COMPANY_LOCAL>` z.B. `/Mitarbyte`, `/Geteilte-Arbeitsplaetze`) gehören dem VM-seitigen `ki-os-cloudsync` und dürfen NIE zusätzlich durch Mutagen laufen (gleiche Drei-Engines-Begründung wie oben; zusätzlich: Mutagen `two-way-resolved` verwirft bei Konflikt den lokalen Edit **kommentarlos**, und auf Cloud-Ordnern sind Fremdänderungen durch Kollegen/KI/Web der Normalfall — stiller Datenverlust). `/Meine-Arbeitsplaetze` + `/dev` sind in dieser Struktur bewusst VM-lokal (dev = Repos/Builds; Meine-Arbeitsplaetze Stufe 1 lokal, später persönliches Drive). `/<COMPANY_LOCAL>` hängt an der Env-Variable `COMPANY_LOCAL` (aus `get-vm-values` auf cloud-VMs) — ohne sie wird der Firmenordner-Ignore nicht gesetzt, der Drift-Check meldet das |

**`.claude/skills` — macOS/Linux vs. Windows:**

- **macOS/Linux: wird bewusst mitgesynct** (kein Ignore). `sync-skills.sh`
  baut die Skill-Symlinks **relativ** in den Sync-Root
  (`../../hub/Skills/<cat>/<skill>`), sie lösen lokal korrekt auf
  `~/KI-OS/hub/Skills/…` auf → klickbare Skill-Ansicht. `.skill-profile`
  (ebenfalls gesynct) bleibt die Quelle, *welche* Skills aktiv sind. Der
  Default-Symlink-Modus (`portable`) toleriert relative In-Root-Links.
- **Windows: `--ignore=".claude/skills"` **und** `--symlink-mode=ignore`.**
  Symlinks brauchen dort `SeCreateSymbolicLinkPrivilege` (Developer-Mode oder
  Admin); ohne das scheitert **jeder** Symlink als *Transition problem*.
  **Der Ignore allein reicht nicht** — der Workspace enthält Symlinks an zwei
  Stellen:

  | Ort | Anzahl (Beispiel-VM) | Ziele |
  |---|---|---|
  | `.claude/skills/*` | 83 | `../../hub/Skills/<cat>/<skill>` |
  | `hub/Skills/*/*/scripts/*.py` | 54 | `../../../../lib/*.py` |

  Alle relativ und *in-root*, also für Mutagen synchronisierbar — die zweite
  Gruppe liegt außerhalb von `.claude/skills` und wird vom Ignore **nicht**
  erfasst. `--symlink-mode=ignore` deckt beide ab; die Zieldateien liegen über
  `hub/lib/` bzw. `hub/Skills/` lokal ohnehin vor. *Welche* Skills aktiv sind,
  zeigt `.skill-profile` und die Cockpit-Skill-Overview.

  **Warum das als „der Sync bleibt dauernd stehen" auffällt:** Mutagen retryt
  fehlgeschlagene Transitions bei jedem Zyklus. Die Session erreicht deshalb
  **nie** `Watching for changes`, sondern steht dauerhaft auf
  `Applying changes` mit `Transition problems: <N>` — obwohl die Dateien
  längst konvergiert sind. `mutagen sync list` verschluckt den Problems-Block
  meist; `mutagen sync list ki-os --long` bzw. `sync monitor` zeigen ihn.

  **Opt-in für die klickbare Skill-Ansicht:** Windows-Developer-Mode
  aktivieren (Einstellungen → System → Für Entwickler), dann die Session ohne
  `--symlink-mode=ignore` **und** ohne den `.claude/skills`-Ignore neu anlegen.

**Ignore-Änderungen wirken nur beim Anlegen:** Eine bestehende Session
übernimmt neue Ignores nicht — einmalig neu anlegen
(`scripts/setup-mutagen.sh --recreate` bzw. `-Recreate`; den VM-User erkennt
das Skript selbst). Dateien bleiben dabei erhalten.

## Konflikt-Semantik (dem User erklären)

- `two-way-resolved`: Bei gleichzeitiger Änderung derselben Datei auf beiden
  Seiten gewinnt die **VM** (Alpha) — die lokale Version wird überschrieben.
- Betriebs-Konvention: **Agent und Mensch bearbeiten nicht gleichzeitig
  dieselbe Datei.** Normale Arbeit erzeugt keine Konflikte.
- Status: `mutagen sync list ki-os` · live: `mutagen sync monitor ki-os` ·
  sofort syncen: `mutagen sync flush ki-os`.

## Blockierte VM-Löschungen (Agent räumt auf, lokal bleibt alles stehen)

**Der wichtigste stille Divergenz-Fall.** Räumt ein Agent auf der VM einen
Ordner weg (z.B. `op-customer/` in den Hub migriert), löscht Mutagen ihn lokal
**nicht**, solange darin **ignorierte** Dateien liegen — es darf sie nicht
mitlöschen, weil es sie nicht verwaltet. Ergebnis:

```
Conflicts:
	(alpha) op-customer                     (Directory -> <non-existent>)
	(beta)  op-customer/walter360/.DS_Store  (<non-existent> -> Untracked content)
```

Der Ordner bleibt lokal **komplett** stehen — **inklusive aller getrackten
Dateien**, nicht nur der ignorierten Reste. **Eine einzige ignorierte Datei
irgendwo tief im Baum reicht dafür.** Auf macOS ist das der Normalfall, weil der
Finder in jeden angesehenen Ordner eine `.DS_Store` legt; dazu kommen `.git`,
`node_modules`, `__pycache__`. Ohne Eingriff divergieren beide Seiten dauerhaft
und **still** — der Status bleibt `Watching for changes`, es sieht gesund aus.

**Automatische Auflösung (seit 2026-07-29).** Der 2-Min-Watchdog verschiebt den
betroffenen Ordner **komplett** in einen lokalen Papierkorb. Danach sind beide
Seiten einig („beidseitig weg"), der Konflikt ist erledigt:

| | |
|---|---|
| Was passiert | der Ordner wandert **ganz** nach `~/.local/state/ki-os/sync-trash/<zeitstempel>/` — nichts wird gelöscht |
| Wann | nur wenn **alle** gemeldeten Reste Wegwerf-Artefakte sind: `.DS_Store`, `Thumbs.db`, `node_modules`, `__pycache__`, `.venv`, `.cache`, `dist`, `.next` |
| Ausnahme | `.git` — dort steckt meist ein lokaler Repo-Klon, in dem gearbeitet wird. Der Block wird **nicht** angefasst, sondern als `SYNC-BLOCK:` gemeldet |
| Logs | macOS `~/Library/Logs/ki-os-mutagen-watchdog.log` · Linux `journalctl --user -u ki-os-mutagen-watchdog` · Windows über `ki-os-vm-watchdog` |

Trockenlauf (zeigt nur, was passieren würde):
`KIOS_SYNC_RESOLVE_DRYRUN=1 ~/.local/bin/ki-os-mutagen-watchdog.sh`

> **Wenn die Auflösung scheitert, sieht man es jetzt** (Lehre aus einem echten
> Ausfall, 2026-08-04 bis 2026-08-12): Auf einem Setup mit Sync-Ordner unter
> `~/Desktop` scheiterte das `mv` an TCC (s.o.) — der Fehler ging nach
> `/dev/null`, das Log blieb **leer**, und weil der Papierkorb-Zielpfad *vor*
> dem `mv` per `mkdir` entstand, wuchs alle 2 min ein weiterer leerer Ordner:
> nach 8 Tagen **3708 leere Ordner**, während die 5 Konflikte unverändert
> standen. Ein „laufender" Watchdog und ein leeres Log waren also beides kein
> Gesundheitsnachweis. Seitdem gilt:
>
> - `mv`-Fehler werden erfasst und als `SYNC-FAIL:` gemeldet, EPERM zusätzlich
>   mit TCC-Anleitung
> - Meldungen erscheinen **nur bei Änderung** gegenüber dem letzten Lauf
>   (`~/.local/state/ki-os/watchdog-issues.last`) — ein Dauerproblem flutet das
>   Log sonst und verdeckt genau das, was neu ist
> - leer gebliebene Papierkorb-Ordner werden am Ende jedes Laufs aufgeräumt
>   (nur **vollständig leere** Verzeichnisse; echte Sicherungen bleiben)

> **Warum der ganze Ordner und nicht nur die Reste** (der Grund ist real
> aufgetreten, 2026-07-29): Räumt man nur die Reste weg, löscht Mutagen den Rest
> des Baums selbst — und nimmt dabei auch Dateien mit, die es **nur lokal** gibt,
> kommentarlos und ohne Sicherung (bei `two-way-resolved` gewinnt alpha). In
> einem in den Hub migrierten Ordner lag noch ein SQL-Dump, den es auf der VM
> nirgends gab; er wäre weg gewesen. Der Papierkorb ist die einzige Variante, bei
> der garantiert nichts verloren geht — `mv` ist ein Rename, also auch bei
> `node_modules` billig.
>
> Praktische Folge für dich: **im Papierkorb nachsehen**, bevor du ihn leerst.
> Dort liegt der letzte lokale Stand des Ordners, inklusive dem, was die VM nie
> gesehen hat.

## Obsidian

Den Vault auf dem **lokalen** Ordner `~/KI-OS` öffnen (Obsidian → „Open
folder as vault"). Friert nicht ein, offline lesbar, schnelle Suche. Die
Vault-Config (`.obsidian/`) kommt von der VM mit; nur die gerätespezifischen
`workspace*`-Dateien sind vom Sync ausgenommen.

## Round-Trip-Test

```bash
touch ~/KI-OS/.sync-test && mutagen sync flush ki-os && \
    ssh ki-os-vm 'ls ~/KI-OS/.sync-test' && \
    rm ~/KI-OS/.sync-test && mutagen sync flush ki-os
```

## Recovery: festgefahrene Session ohne Neuanlage

Für den Fall „steht auf `Applying changes`, `sync pause` hängt, Daemon-CPU
bewegt sich nicht". **Reihenfolge einhalten** — und `terminate`/`--recreate`
hier ausdrücklich **nicht** benutzen (dazu unten).

```powershell
# 1. Diagnose: bewegt sich der Daemon ueberhaupt?
$p = Get-Process mutagen; $c = $p.CPU; Start-Sleep 10; $p.Refresh()
"CPU-Delta in 10s: $([math]::Round($p.CPU - $c, 2))s"   # ~0 = blockiert

# 2. Transport-Binary pruefen (s.o.) und ggf. MUTAGEN_SSH_PATH setzen
[Environment]::SetEnvironmentVariable('MUTAGEN_SSH_PATH','C:\Windows\System32\OpenSSH','User')
$env:MUTAGEN_SSH_PATH = 'C:\Windows\System32\OpenSSH'

# 3. Haengende CLI-Aufrufe wegraeumen (ein blockierter `sync flush` bleibt sonst ewig stehen)
Get-CimInstance Win32_Process -Filter "Name='mutagen.exe'" |
    Where-Object { $_.CommandLine -match 'sync\s+(flush|monitor)' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# 4. Daemon hart neu starten - der Ancestor liegt auf Platte und bleibt erhalten
mutagen daemon stop; Get-Process mutagen -EA SilentlyContinue | Stop-Process -Force
Start-Process -WindowStyle Hidden -FilePath "$env:USERPROFILE\.local\bin\mutagen.exe" -ArgumentList 'daemon','run'
mutagen sync resume ki-os
```

Auf der VM zusätzlich die **verwaiste** sshd-Session des toten Transports
abräumen — die mit `@notty` **ohne** `mutagen-agent`-Child. Die sshd-Prozesse
der Tunnel (deutlich älter, mehrere Tage) dabei **nicht** anfassen:

```bash
ssh ki-os-vm 'ps -eo pid,etime,cmd | grep "sshd: $USER"'   # erst schauen
ssh ki-os-vm 'ps -eo pid,cmd | grep "mutagen-agent"'       # welcher Agent lebt?
```

Ein **Daemon-Hard-Kill ist unkritisch**: `~/.mutagen/sessions/<id>` (Konfig) und
`~/.mutagen/archives/<id>` (Ancestor) liegen auf Platte, der Daemon lädt sie beim
Start wieder. `terminate`/`--recreate` dagegen **verwirft den Ancestor** — siehe
nächster Abschnitt.

## Warum `--recreate` bei Divergenz gefährlich ist

Eine Neuanlage startet **ohne Ancestor**. Mutagen kann dann nicht mehr
unterscheiden „lokal gelöscht, weil auf der VM gelöscht" von „lokal neu
angelegt" — alles, was nur auf einer Seite liegt, wird als **Neuanlage** auf die
andere gespült. Standen also z.B. 9 GB nur lokal, landen sie auf der VM.

**Vor jedem `--recreate`/`-Recreate` prüfen, dass beide Seiten konvergiert
sind:**

```bash
mutagen sync list ki-os     # alpha und beta: gleiche Verzeichnis-/Dateizahl
```

**Die Endpunkte übernimmt die Neuanlage aus der bestehenden Session** (alpha-URL
und beta-URL werden vor dem `terminate` ausgelesen), *nicht* aus der Konvention
`ki-os-vm:/home/<user>/KI-OS` ↔ `~/KI-OS`. Das ist für Bestands-Setups
entscheidend: Wer einen anderen SSH-Alias oder einen anderen lokalen Ordner hat
(z.B. `~/Desktop/KI-OS`), bekäme sonst eine Neuanlage auf einen fremden Alias
und einen fast leeren Ordner — bei terminierter, funktionierender Session. Sind
die Endpunkte nicht lesbar, bricht das Skript ab und terminiert **nichts**.

Ist die Session zwar wegen Transition problems festgefahren, aber die
**Zahlen stimmen auf beiden Seiten überein**, ist die Neuanlage gefahrlos —
die Symlink-Retries sind dann das Einzige, was fehlt. Weichen sie ab: erst
unwedgen (Recovery oben) und konvergieren lassen, **dann** neu anlegen.
`setup-mutagen.sh`/`.ps1` melden Konfig-Drift von sich aus (`DRIFT:`) und
weisen genau darauf hin.

## Troubleshooting

| Symptom | Lösung |
|---------|---------|
| Dauerhaft `Applying changes`, Zahlen auf beiden Seiten identisch, `Transition problems: N` | Symlinks ohne Developer Mode — `--symlink-mode=ignore` (Session neu anlegen) oder Developer Mode an. Der Watchdog heilt das **nicht** |
| Dauerhaft `Applying changes`, Daemon-CPU-Delta ~0, `sync pause` hängt | Toter Agent-Transport → „Recovery" oben. Transport-Binary auf Git-Bash-ssh prüfen |
| VM: `<user>@notty`-sshd-Session ohne `mutagen-agent`-Child | Verwaister Transport — Prozess killen, Daemon neu starten (Recovery oben) |
| VM: Dateien für andere Mitarbeiter nicht lesbar/schreibbar (`Workspaces/`) | Shared-Group fehlt in der Session → `DRIFT:`-Meldung von `setup-mutagen`, mit `--recreate` neu anlegen (s. „Shared-Group") |
| Ordner auf der VM gelöscht, liegt lokal noch komplett da (Status trotzdem `Watching for changes`) | Ignorierte Reste blockieren die Löschung → „Blockierte VM-Löschungen". Der Watchdog löst das binnen ~2 min selbst; `SYNC-BLOCK:` im Log heißt `.git` betroffen → selbst entscheiden |
| `Transition problems: N` mit `unable to relocate staged file: file exists` bei Dateien mit Umlaut | **NFC/NFD-Duplikat auf der VM**: Linux erlaubt `Erstgespräch.md` zweimal — einmal NFC (`ä` = U+00E4), einmal NFD (`a`+U+0308). macOS/APFS ist normalisierungs-*insensitiv* und kann nur eine davon halten, die zweite scheitert dauerhaft. Sichtbar machen: `ssh ki-os-vm 'ls ~/KI-OS/<pfad> \| cat -v'` (NFC = `M-CM-$`, NFD = `aM-LM-^H`). Fix ist **VM-seitig und inhaltlich**: die beiden Dateien vergleichen und eine behalten (`mv`/`rm`). Bis dahin bleibt die Session um genau diese Dateien divergent — und damit ist auch kein `--recreate` gefahrlos |
| `mutagen: command not found` (Windows) | Neue PowerShell-Session öffnen (PATH-Update) oder `%USERPROFILE%\.local\bin\mutagen.exe` direkt aufrufen |
| „Connecting…" dauerhaft | SSH testen: `ssh -o BatchMode=yes ki-os-vm true` — wenn das hängt, ist es ein SSH-/Netz-Problem |
| „Conflicts" in `mutagen sync list` | `mutagen sync list ki-os --long` zeigt die Dateien; VM-Version gewinnt beim nächsten Sync — lokale Änderung vorher wegsichern, falls gebraucht |
| Daemon läuft nach Reboot nicht | macOS: `mutagen daemon register` + `start` erneut · Linux: Linger/Unit prüfen (`loginctl enable-linger`) · Windows: `ki-os-vm-watchdog`-Task prüfen (`AtLogOn` feuert nur beim echten Login) |
| Sync tot nach VM-Idle-Suspend, kommt nicht wieder (VM-seitig toter `mutagen-agent`) | Session steckt in `paused`/`halted` — der Session-Watchdog resumt binnen ~2 min; sofort: `mutagen sync resume ki-os`, bei `halted` `mutagen sync reset ki-os` (rescan, danach `resume`). Watchdog fehlt? `setup-mutagen.sh` erneut laufen lassen |
| Session steht auf `[Paused]` | `mutagen sync resume ki-os` (macht der Watchdog automatisch) |
| Daemon-Unit failed: „daemon already running" (Linux) | `mutagen daemon stop`, dann `systemctl --user restart mutagen-daemon.service` |
| Watchdog-Task „beendet sich sofort" (Windows) | Erwartet: der 2-Min-Tick sieht laufende Tunnel + Daemon und beendet sich — die Prozesse selbst laufen weiter (`Get-Process mutagen`) |
| Daemon-Fenster geht beim Login auf (Windows) | Alter Task startet `mutagen.exe` noch sichtbar — `setup-tunnels.ps1` erneut laufen lassen (konsolidiert inhaltsbasiert auf den unsichtbaren `ki-os-vm-watchdog`) |
| Session kaputt/falsch konfiguriert | `--recreate`/`-Recreate` — Dateien bleiben erhalten |
| Erst-Sync dauert lange | Normal bei großem Workspace — `mutagen sync monitor ki-os` zeigt Fortschritt |
| Sync-Fehler wegen Symlinks (Windows) | `.claude/skills`-Ignore fehlt in der Session → mit `-Recreate` neu anlegen |
| `KI-OS/Ablage` (bzw. `KI-OS/SharePoint`) erscheint lokal / Konfliktkopien im Cloud-Sync-Ordner | Der passende Ignore fehlt in der Session (`DRIFT:`-Meldung) → mit `--recreate`/`-Recreate` neu anlegen. **Vorher** beide Seiten konvergieren lassen, sonst spült der frische Ancestor die heruntergeladenen Dateien als Neuanlage hoch |
