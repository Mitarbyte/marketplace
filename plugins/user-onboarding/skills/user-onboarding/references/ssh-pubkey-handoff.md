# SSH-Pubkey an Admin uebergeben

Schritt 3 des Skills generiert einen Ed25519-Pubkey lokal. Bevor du
weitermachen kannst, muss der Admin diesen Key auf der VM hinterlegen.
Diese Datei sammelt sinnvolle Uebergabe-Vorlagen — der Skill bietet sie
in der Reihenfolge an, die zur User-Situation passt (Slack > Mail >
Plain-Copy).

## Mail-Vorlage

```
Betreff: KI-OS Zugang — SSH-Pubkey fuer <Username>

Hi Admin,

mein lokales Setup ist soweit fertig. Bitte leg meinen User auf der
Firmen-VM an:

  Username-Vorschlag:  <VM_USER>
  Display-Name:        <DISPLAY_NAME>
  Email:               <EMAIL>

SSH-Pubkey:
ssh-ed25519 AAAA... <EMAIL>

Sobald der User steht und der Key drauf ist, gib mir kurz Bescheid —
dann mache ich den Smoketest und den Rest des Setups.

Danke!
```

## Slack-Vorlage (kuerzer)

```
Hi! Pubkey fuer KI-OS-VM (User: <VM_USER>):
`ssh-ed25519 AAAA... <EMAIL>`
```

## Was der Admin damit macht

Der Admin richtet mit dem Pubkey deinen User auf der VM komplett ein:
Linux-User + SSH-Key, Workspace `/home/<VM_USER>/KI-OS` (1:1-Klon von
einem bestehenden User), Cockpit-Service und Display-Stack (noVNC).
Du brauchst dafuer nichts zu tun — nur auf seine Bestaetigung warten.

## Verifikation auf User-Seite

Sobald der Admin Bescheid gibt, im Skill weitermachen — Schritt 6
macht den Connection-Smoketest:

```bash
ssh -o BatchMode=yes <SSH_ALIAS> true
```

Wenn Exit-Code 0: Key ist drauf, weiter zu Schritt 7. Wenn nicht:
- "Permission denied (publickey)" → Admin hat Key noch nicht hinterlegt
  oder falscher Pubkey-Inhalt
- "Connection refused" → VM-IP/Port falsch, oder VM down
- "Host key verification failed" → einmalig `ssh-keygen -R <VM_IP>`,
  dann `ssh <SSH_ALIAS>` manuell zum Akzeptieren des Host-Keys

## Sicherheitshinweise

- **Pubkey ist nicht geheim** — er darf in Slack, Mail, sogar im Chat
  geteilt werden. Privatschluessel (`~/.ssh/id_ed25519` ohne `.pub`)
  bleibt strikt lokal.
- **Email mit Pubkey ist kein Verschluesselungs-Faktor.** Wer den
  Pubkey hat, kann sich nicht einloggen — er muss vom Admin auf
  der VM hinterlegt werden. Pubkey-Diebstahl ist daher kein Risiko.
- Trotzdem: bei laufender Email-Vorlage **die Email nicht laut
  vorlesen** in Gegenwart Unbeteiligter — wer den Username sieht,
  weiss zumindest, dass es eine VM-Identitaet gibt.
