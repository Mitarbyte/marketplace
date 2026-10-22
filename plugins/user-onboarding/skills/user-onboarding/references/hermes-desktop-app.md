# Hermes-Desktop-App verbinden (Hermes-Paket)

Gegenstück zu `desktop-app.md`: für das Hermes-Paket gibt es **keine lokale
Registrierung** — keine `ssh_configs.json`, kein `~/.claude.json`-Eintrag.
Die Hermes-Desktop-App verbindet sich als **„Remote gateway"** direkt mit dem
Agenten auf der VM: eine URL, dann dein Firmen-Login. Die App ist **Pflicht**:
dort arbeitest du mit dem Agenten, und nur dort steuerst du seinen
Bildschirm (Screen).

> [!important] Kein Token, kein VM-Desktop im Browser
> Du meldest dich mit **demselben Firmen-Login** an wie im Browser (ADR § 5.6h);
> es gibt kein Geheimnis, das du aufbewahren oder geschützt übertragen musst.
> Einen VM-Desktop im Browser gibt es für das Hermes-Paket nicht — Anmeldungen
> auf der VM laufen im **Screen der App**.

## Verbinden

Download: https://hermes-agent.nousresearch.com/desktop (macOS, Windows,
Linux; installiert in Teil 2 der Anleitung). In der App unter
**Settings → Gateways → Remote gateway** die Agent-URL eintragen:
`https://<VM_USER>-agent.<base-domain>` — aus der Übergabe-Nachricht (Pfad H)
bzw. `GATEWAY_AGENT_URL` aus Schritt 7. Der Admin liest sie mit
`ki-os-fleet vm zugang --user <VM_USER>` aus.

Danach meldet dich die App an: sie öffnet deinen **System-Browser** mit dem
Firmen-Login (RFC 8252 + PKCE), du meldest dich wie gewohnt an, und die App
übernimmt die Sitzung.

Auf **Pfad H** (nur Hermes-Paket) ist das die komplette Einrichtung: kein
SSH-Key, kein Skript, kein VM-Zugriff vom eigenen Gerät (ADR 22 Nr. 10).

## Screen: Anmeldungen auf der VM

Der Agent hat auf der VM einen eigenen Bildschirm mit Browser. Die App zeigt
ihn als **Screen** — oben unter **Bots → Bot → Scheduled Jobs**, per
Rechtsklick auf den Bot → **Open Screen** oder als Screen-Box unter dem Profil
in der Sessions-Leiste.

- **Live-Bild:** du siehst, was der Agent gerade tut; der Kopf zeigt, wer
  steuert („Bot is in control").
- **Übernehmen** („Take over"): der Rahmen wird rot, Tastatur und Maus steuern
  jetzt den Screen. Anmelden, 2FA, Captcha bestätigen. Der Agent ist solange
  gesperrt.
- **Zurückgeben** („Hand back"): der Agent steuert wieder und arbeitet mit der
  Sitzung weiter, die du gerade angemeldet hast. Den Screen schließen gibt
  ebenfalls zurück; bricht nur die Verbindung ab, behältst du die Steuerung bis
  zum Zurückgeben (nach einem Neuladen: **Hand back (force)**).
- **Tastatur läuft mit US-Belegung.** Beim Übernehmen sind auf einer
  deutschen Tastatur Y und Z vertauscht; Sonderzeichen und Umlaute landen als
  das Zeichen, das auf einer US-Tastatur an derselben Stelle liegt. Passwörter
  darum vor dem Absenden prüfen oder per Zwischenablage einfügen (Einfügen in
  den Screen funktioniert).

Firmen-Tools (Outlook, SharePoint, …) meldest du so an: dem Agenten sagen
„Melde mich bei Outlook an" oder im Dashboard (Agent-URL im Browser) Tab
**KI-OS → Anmeldungen** → „Anmelden". Der Login öffnet sich im Screen:
**Desktop-App → Screen → Übernehmen**, anmelden, **Zurückgeben**. Website-Logins
(CRM, Google, …) genauso: übernehmen, im Browser des Screens anmelden,
zurückgeben — die Sitzung bleibt auf der VM.

## Wie die Anmeldung funktioniert

- Deine Sitzung in der App ist **dieselbe** wie im Browser — angemeldet wird
  einmal, beim Firmen-IdP. Das Dashboard prüft kein eigenes Passwort: es
  vertraut der Identität, die der Gateway bestätigt hat.
- Nichts läuft „für immer": die Sitzung endet wie jede andere Firmen-Sitzung,
  die App erneuert sie im Hintergrund.
- Zugang entziehen heißt darum: Zugang **im IdP** entziehen — nicht beim Admin
  ein Token rotieren lassen.

## Was du vom Admin brauchst (Vorlage für die Anfrage)

Nicht geheim, darf per Mail kommen:

```
Hi Admin,

mein lokales Setup für die Hermes-Desktop-App steht. Schickst du mir
meine Agent-URL (https://<VM_USER>-agent.…)?

(ki-os-fleet vm zugang --user <VM_USER>)

Danke!
```

## Troubleshooting

| Symptom | Ursache / Fix |
|---|---|
| App verbindet nicht | Agent-URL im Browser öffnen: landest du beim Firmen-Login, ist der Gateway in Ordnung — dann in der App neu anmelden. Fehlerseite/Timeout = Admin |
| Anmeldung öffnet den Browser, kommt aber nicht zurück | Der Rücksprung geht an die App; Pop-up-/Standardbrowser-Blocker prüfen und erneut versuchen. Bleibt es dabei: Admin (`/auth/native/token` muss **422** antworten, nicht 302) |
| 401 nach funktionierender Kopplung | Sitzung abgelaufen oder im IdP beendet — in der App neu anmelden |
| Screen zeigt kein Bild / „Start screen" | „Start screen" klicken; startet er nicht, den Admin bitten (er prüft `ki-os-fleet vm doctor`, Check `bot-screen`) |
| Agent meldet `human_has_control` | Du hältst noch die Steuerung: im Screen **Zurückgeben** (bzw. **Hand back (force)**) |
| Falsche Zeichen beim Tippen im Screen | US-Belegung, siehe oben |

## Abgrenzung

- `desktop-app.md` (Claude-Code-Desktop-App) gehört zum Claude-Paket. Hat die
  VM beide Pakete, kommt sie zusätzlich dazu; jedes Paket hat dann ein eigenes
  Chrome-Profil — Website-Logins einmal im Screen, einmal im VM-Desktop.
