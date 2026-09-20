# Hermes-Desktop-App verbinden (engine=hermes|hybrid)

Gegenstück zu `desktop-app.md`: auf `engine=hermes` gibt es **keine lokale
Registrierung** — keine `ssh_configs.json`, kein `~/.claude.json`-Eintrag.
Die Hermes-Desktop-App verbindet sich stattdessen als **„Remote gateway"**
direkt mit dem Dashboard auf der VM: eine URL, dann dein Firmen-Login.

> [!important] Es gibt keinen Session-Token mehr
> Bis zum 20.09.2026 brauchte die App neben der URL ein Dauer-Geheimnis, das
> der Admin ausgab. Das ist abgeschafft (ADR § 5.6h): du meldest dich mit
> **demselben Firmen-Login** an wie im Browser. Nichts mehr, was du aufbewahren
> oder geschützt übertragen musst.

## Verbinden

Download: https://hermes-agent.nousresearch.com/desktop (macOS, Windows,
Linux; installiert in Teil 2 der Anleitung). In der App unter
**Settings → Gateways → Remote gateway** die Dashboard-URL eintragen:

| Zugangs-Modus der VM | URL |
|---|---|
| `gateway` | `https://<VM_USER>-agent.<base-domain>` — die Dashboard-URL aus der Übergabe-Nachricht (Pfad H) bzw. `GATEWAY_AGENT_URL` aus Schritt 7 |
| `tunnel` (auslaufend) | `http://127.0.0.1:9119` — der Hermes-Default der App; der Tunnel aus Schritt 8 macht genau diese Adresse lokal verfügbar |

Danach meldet dich die App an: sie öffnet deinen **System-Browser** mit dem
Firmen-Login (RFC 8252 + PKCE), du meldest dich wie gewohnt an, und die App
übernimmt die Sitzung. Der Admin liest die Werte mit
`ki-os-fleet vm hermes-token --user <VM_USER>` in einem aus: Dashboard-URL und
**VM-Desktop-URL** (noVNC im Browser, Firmen-Login — dort laufen alle
Anmeldungen bei Firmen-Tools).

Auf `gateway` ohne Cockpit (**Pfad H**) ist das die komplette Einrichtung: kein
SSH-Key, kein Skript, kein VM-Zugriff vom eigenen Gerät (ADR 22 Nr. 10).
Firmen-Tools meldest du danach im Dashboard-Tab **KI-OS → Anmeldungen** an
(„Anmelden" öffnet den Login im VM-Desktop).

## Wie die Anmeldung funktioniert

- Deine Sitzung in der App ist **dieselbe** wie im Browser — angemeldet wird
  einmal, beim Firmen-IdP. Das Dashboard prüft kein eigenes Passwort: es
  vertraut der Identität, die der Gateway bestätigt hat (Mail + ein
  Per-User-Geheimnis, das nur der Gateway setzt).
- Nichts läuft „für immer": die Sitzung endet wie jede andere Firmen-Sitzung,
  die App erneuert sie im Hintergrund. Es gibt kein Geheimnis, das du in einen
  Passwort-Manager legen oder bei Verdacht rotieren lassen müsstest.
- Zugang entziehen heißt darum: Zugang **im IdP** entziehen — nicht beim Admin
  ein Token rotieren lassen.

## Was du vom Admin brauchst (Vorlage für die Anfrage)

Beides ist **nicht geheim** und darf per Mail kommen:

```
Hi Admin,

mein lokales Setup für die Hermes-Desktop-App steht. Schickst du mir

  1. meine Dashboard-URL   (https://<VM_USER>-agent.…)
  2. den VM-Desktop-Link   (https://<VM_USER>-vnc.…/vnc.html)

(beides: ki-os-fleet vm hermes-token --user <VM_USER>)

Danke!
```

## Troubleshooting

| Symptom | Ursache / Fix |
|---|---|
| App verbindet nicht (gateway) | `https://<user>-agent.<base>` im Browser öffnen: landest du beim Firmen-Login, ist der Gateway in Ordnung — dann in der App neu anmelden. Fehlerseite/Timeout = Admin (`ki-os-gateway-render --check`) |
| Anmeldung öffnet den Browser, kommt aber nicht zurück | Der Rücksprung geht an die App; Pop-up-/Standardbrowser-Blocker prüfen und erneut versuchen. Bleibt es dabei: Admin (`/auth/native/token` muss **422** antworten, nicht 302 — sonst fehlt die IdP-freie Zone) |
| 401 nach funktionierender Kopplung | Sitzung abgelaufen oder im IdP beendet — in der App neu anmelden |
| Dashboard selbst tot (auch im Browser) | Admin kontaktieren — `ki-os-fleet vm doctor --user <VM_USER>` bzw. `systemctl --user status hermes-dashboard` auf der VM |
| App verbindet nicht (tunnel) | Lauscht `localhost:9119`? → `references/tunnels.md` (Watchdog zieht binnen 2 min nach); sonst Tunnel-Setup (Schritt 7) erneut |

## Bestands-VMs auf Pin `v2026.8.19`

Der Firmen-Login der App hängt am Hermes-Pin **`v2026.9.14`**. Steht eine VM
noch auf `8.19`, verbindet die App dort weiter mit **URL + Session-Token** —
`ki-os-fleet vm hermes-token --user <VM_USER>` gibt ihn dann mit aus, und er
gehört in einen geschützten Kanal (nie in eine Klartext-Mail). Der Absatz
verschwindet, sobald die letzte VM gehoben ist; welche noch offen sind, steht
in [`vms.md`](../../../../vms.md).

## Abgrenzung

- Auf `engine=hermes|hybrid` ist die App **Pflicht**: dort arbeitet der
  Mitarbeiter mit dem Agenten. Der Browser bleibt Fallback, wenn die App
  gerade nicht verbindet (gateway: Agent-URL + Firmen-Login; tunnel:
  `http://localhost:9119`).
- `desktop-app.md` (Claude-Code-Desktop-App) gilt auf `hermes` **nicht** —
  es gibt dort nichts lokal zu registrieren. Auf `hybrid` kommt sie
  zusätzlich dazu.
