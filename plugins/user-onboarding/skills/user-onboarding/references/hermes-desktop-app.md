# Hermes-Desktop-App verbinden (nur engine=hermes)

Gegenstück zu `desktop-app.md`: auf `engine=hermes` gibt es **keine lokale
Registrierung** — keine `ssh_configs.json`, kein `~/.claude.json`-Eintrag.
Die Hermes-Desktop-App verbindet sich stattdessen als **„Remote gateway"**
direkt mit dem Dashboard auf der VM: eine URL + ein Session-Token, fertig.

## Verbinden

In der App **Remote gateway** wählen und eintragen:

| Zugangs-Modus der VM | URL |
|---|---|
| `tunnel` | `http://127.0.0.1:9119` — der Hermes-Default der App; der Tunnel aus Schritt 7 macht genau diese Adresse lokal verfügbar, nichts umzutippen |
| `gateway` | `https://<VM_USER>-agent.<base-domain>` — die Agent-URL aus der Übergabe-Nachricht bzw. `GATEWAY_AGENT_URL` aus Schritt 6 |

Dazu den **Session-Token** — den bekommst du von deinem Admin (er liest ihn
mit `ki-os-fleet vm hermes-token --user <VM_USER>` aus).

## Token-Semantik

- Der Token ist die Auth der App gegen die `/api/*`-Zone deines Dashboards.
  Er **läuft nicht ab** — behandle ihn wie ein Passwort (Passwort-Manager,
  nie in Chats/Notizen liegen lassen).
- Bei Verdacht auf Leak rotiert der Admin ihn
  (`ki-os-fleet vm hermes-token --user <VM_USER> --rotate`) — danach sind
  **alle** bestehenden App-Kopplungen ungültig und du verbindest die App
  einmal neu.
- Auf der VM liegt er in `~/.hermes/.env` (nur für dich lesbar, 600).

## Token-Übergabe (Vorlage für die Anfrage an den Admin)

Anders als der SSH-**Pub**key (`ssh-pubkey-handoff.md`) ist der Token
**geheim** — er gehört in einen geschützten Kanal (Passwort-Manager-Sharing,
Bitwarden Send o. ä.), **nie** in eine Klartext-Mail. Die Vorlage enthält
deshalb nur die Bitte, nicht den Token selbst:

```
Hi Admin,

mein lokales Setup für die Hermes-Desktop-App steht. Schickst du mir
bitte über einen geschützten Kanal (1Password/Bitwarden Send):

  1. meine Dashboard-URL   (gateway: https://<VM_USER>-agent.…;
                            tunnel: bestätige einfach 127.0.0.1:9119)
  2. meinen Session-Token  (ki-os-fleet vm hermes-token --user <VM_USER>)

Danke!
```

## Troubleshooting

| Symptom | Ursache / Fix |
|---|---|
| App verbindet nicht (tunnel) | Lauscht `localhost:9119`? → `references/tunnels.md` (Watchdog zieht binnen 2 min nach); sonst Tunnel-Setup (Schritt 7) erneut |
| App verbindet nicht (gateway) | `https://<user>-agent.<base>` im Browser öffnen: 302 zum Firmen-Login = Gateway ok, dann stimmt vermutlich der Token; Fehlerseite/Timeout = Admin (`ki-os-gateway-render --check`) |
| 401 nach funktionierender Kopplung | Admin hat rotiert — neuen Token holen, App neu verbinden |
| Dashboard selbst tot (auch im Browser) | Admin kontaktieren — `ki-os-fleet vm doctor --user <VM_USER>` bzw. `systemctl --user status hermes-dashboard` auf der VM |

## Abgrenzung

- Browser reicht völlig: das Dashboard läuft auch ohne App (tunnel:
  `http://localhost:9119`; gateway: Agent-URL + Firmen-Login). Die App ist
  Komfort, kein Muss.
- `desktop-app.md` (Claude-Code-Desktop-App) gilt hier **nicht** — es gibt
  auf hermes nichts lokal zu registrieren.
