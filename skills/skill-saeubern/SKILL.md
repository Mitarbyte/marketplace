---
name: skill-saeubern
description: "Skill teilen oder anonymisieren: legt eine Kopie ohne Personen-, Kunden- und Firmendaten an. Das Original bleibt unverändert."
---

# Skill vor dem Teilen säubern

Macht aus einem Skill eine Kopie, die man mit anderen Verwaltungen teilen kann. In der Kopie steht nichts mehr, was auf Personen, die eigene Verwaltung oder deren Kunden schließen lässt. Das Original wird nie verändert.

## Ablauf

1. Skill bestimmen. Ist nicht eindeutig, welcher gemeint ist, nachfragen. Alle Dateien im Skill-Ordner lesen, auch in Unterordnern.
2. Kopie anlegen in einem neuen Ordner `<skill-name>-geteilt`, nicht im Skills-Verzeichnis (sonst gibt es den Skill doppelt), zum Beispiel in der Outbox. Steckt im Skill-Namen ein Firmen- oder Personenname, Namen und Ordner der Kopie neutral benennen. Nur Textdateien kopieren. Bilder, PDFs, Office- und andere Binärdateien nicht mitnehmen, sondern im Bericht auflisten.
3. In der Kopie ersetzen, durch Platzhalter in eckigen Klammern. Gleiche Angabe, gleicher Platzhalter ([Person 1], [Objekt A], [Ordner Eingangsrechnungen]), damit der Skill lesbar bleibt:
   - Personen: Namen, Kürzel, Unterschriften, auch von Kolleginnen und Kollegen
   - Kontaktdaten: E-Mail-Adressen, Telefonnummern, Anschriften
   - Eigentümer, Mieter, Beiräte, Dienstleister: alle Angaben
   - Objekte: Straßen, Hausnummern, WEG-Bezeichnungen, Objekt- und Wohnungsnummern
   - Eigene Verwaltung: Firmenname, Domains, Benutzernamen, Pfade und Ordner mit dem Firmennamen
   - Nummern: IBAN, Kunden-, Vertrags- und Rechnungsnummern, Aktenzeichen
   - Interna: Freigabegrenzen, Konditionen, Absprachen mit einzelnen Auftraggebern
   - Beispiele aus echten Fällen (Mails, Briefe, Protokolle): durch kurze, erkennbar erfundene Beispiele ersetzen
4. Zugangsdaten löschen, nicht umschreiben: Passwörter, Tokens, API-Schlüssel, Links mit Zugangsschlüssel. An ihre Stelle kommt [eigenen Zugang hier hinterlegen].
5. Bei Software- und Portalnamen nachfragen statt raten: Sie dürfen bleiben, wenn der Skill davon abhängt. Die Kombination mehrerer Systeme kann eine Verwaltung aber erkennbar machen.
6. Zweiter Durchgang: die Kopie vollständig neu lesen und gezielt suchen nach @, Telefonnummern, IBAN (DE und 20 Ziffern), Postleitzahlen, http, token, key, passw, dem Firmennamen und allen Namen aus Schritt 3. Treffer beheben.
7. An den Anfang der Kopie zwei, drei Sätze: wofür der Skill ist, was er voraussetzt und was er bewusst nicht macht.
8. Bericht im Chat: Liste „vorher → Platzhalter“, gelöschte Zugangsdaten, nicht mitgenommene Dateien, offene Fragen. Diese Liste nie in die Kopie schreiben.

## Regeln

- Das Original nie ändern.
- Im Zweifel ersetzen und im Bericht nennen.
- Nur Angaben ersetzen, nicht die Arbeitsweise des Skills.
- Die Kopie nie selbst verschicken, hochladen oder posten. Ob und wo geteilt wird, entscheidet der Mensch, nachdem er die Kopie gelesen hat.
