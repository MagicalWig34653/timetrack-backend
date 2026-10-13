# Timetrack – Produktkonzept

Stand: 13.10.2026. Kein implementiertes Produkt. Bestätigt = Nutzervorgabe;
Vorschlag = fachliche Ausarbeitung, noch nicht ausdrücklich bestätigt.
Technik: [Architektur](ARCHITEKTUR.md). Umsetzung: [Etappen](UMSETZUNG.md).

## 1. Ziel und Nutzerkreis – bestätigt

Selbst hostbare Zeittracking-Lösung unter AGPLv3, mit Backend, PWA und später Apple-Apps.
Mehrere getrennte Konten pro Server von Beginn an. Registrierung nur mit Token/Einladungslink.
Nutzer sehen gegenseitig keine privaten Daten. Zeitplanfreigaben für ausgewählte Nutzer derselben
Instanz sind möglich. Keine Team-Genehmigungshierarchie im ersten Umfang.

Der Nutzer ist Auszubildender mit anschließender Anstellung; Historie und Berichtshefte bleiben erhalten. Selbstständigenfunktionen dürfen später kommen.
Die Umsetzung übernimmt Claude Code. Fragen gesammelt im normalen Chat, nicht interaktiv stellen.

## 2. Arbeitsmodelle – bestätigt

- Sollzeit frei täglich oder wöchentlich konfigurierbar. Aktuell 38,5 Stunden/Woche, lockere Kernzeiten.
- Regeln mit Gültigkeitszeitraum; Vertragswechsel verändert nicht still frühere Zeiten.
- Berufsschule betriebsspezifisch: beim Nutzer ab 4 × 45 Minuten voller 7,7-Stunden-Tag (7:42).
  Unabhängig vom Unterrichtsumfang aktuell keine Rückkehr zur Arbeit nötig.
  Unterhalb der Schwelle ergänzt der Nutzer die übrigen Stunden manuell; nicht automatisch
  auf einen vollen Tag auffüllen. Keine automatische Rückkehrpflicht daraus ableiten.
- Nutzer ist erwachsen; persönliches Rechtsprofil für Erwachsene vorsehen.
- Wege zwischen HO, Büro und Kunden zählen beim Nutzer als Arbeit, frei konfigurierbar.
- Über-/Unterstunden, Übertrag und Ausgleich frei konfigurierbar, Anfangsstände möglich.
- Deutschland/Sachsen-Anhalt als persönliches Profil; Land und Region frei wählbar.

Vorschlag: Wochen-Soll mit Verteilung auf Arbeitstage oder explizite Tages-Sollwerte, klare
Vorrangregel. Bei reinem Wochen-Soll braucht die Abwesenheitsbewertung eine definierte Tagesbasis.
Änderungen ab Stichtag, rückwirkende Neubewertung ausdrücklich wählen. Keine doppelte Gutschrift
bei Überschneidungen von Schule, Feiertag, Urlaub und Krankheit.

## 3. Erfassung und Automatik

Bestätigt:

- Timer und manuelle Einträge, mehrere Arbeitsabschnitte und Orte pro Tag.
- HO bewusst per Button/Shortcut starten/stoppen, folgenden Bürobesuch automatisch erkennen.
- Je Arbeitsort direkte Buchung, Vorschlag zur Bestätigung oder aus; global abschaltbar.
- Vorbeifahren darf keine Arbeitsbuchung auslösen. Besprochener Ausgangspunkt: etwa fünf Minuten
  bestätigter Aufenthalt, anschließend auf ursprüngliche Ankunft zurückdatieren.
- Feste Pausenzeiten hinterlegen, pro Tag überspringbar mit Hinweis zur rechtlichen Einordnung.
- Viertelstunden-Rundung zugunsten des Arbeitnehmers, optional und standardmäßig aktiv.
  Beim Verlassen Arbeitsende zur nächsten Viertelstunde aufrunden.

Bestätigte Rundungsregel: nur ersten Arbeitsbeginn und letztes Arbeitsende des Tages runden,
Beginn abrunden, Ende aufrunden. Pausen und innere Abschnittsgrenzen bleiben unverändert.
Rohsignale, tatsächliche/korrigierte Abschnitte und Bewertung getrennt speichern.
Exakte Viertelstunden unverändert lassen.
Beispiel ohne Pause: 08:07–16:02 ergibt bewertet 08:00–16:15.
Arbeitsfreie Lücken zwischen Abschnitten bleiben arbeitsfrei; nicht den gesamten Tagesrahmen
als Arbeit zählen. Ein reiner Ortswechsel erzeugt keine zusätzlichen Rundungsgewinne oder
Doppelbuchungen. Exporte kennzeichnen Ist/Bewertung. Für Nachtschichten die Zuordnung zu einem
fachlichen Arbeitstag technisch spezifizieren, damit Mitternacht keine doppelte Rundung erzeugt.

Ein bloßer Server-Timer ohne weitere Standortinformation beweist keinen Aufenthalt.
Fehlendes Verlassen-Signal nicht als Anwesenheitsnachweis werten. Mit Shortcuts auf echten Geräten
erproben; unklare Fälle als Vorschlag behandeln. Rundung und technische Erkennung des Verlassens trennen.

Pausenvorlagen nur innerhalb aktiver Arbeitszeit anwenden, Überschneidungen nicht doppelt abziehen.
Eine übersprungene Pause bleibt als tatsächliche Arbeit erfasst. Keine Pause zur vermeintlichen
Rechtskonformität erfinden. Regelbasierte Hinweise sind keine verbindliche Rechtsprüfung.

Standardprofil Erwachsene/Deutschland nach § 4 ArbZG: grundsätzlich 30 Minuten Pause bei mehr
als sechs bis neun Arbeitsstunden, darüber 45 Minuten; Teilpausen mindestens 15 Minuten und
keine Arbeit länger als sechs Stunden ohne Pause. Quellenstand/Rechtsprofil anzeigen und vor
Implementierung fachlich validieren. Jugendliche und Sonderfälle brauchen eigene geprüfte Regeln.
Quelle: https://www.gesetze-im-internet.de/arbzg/__4.html

## 4. Urlaub, Abwesenheit und Planung

Bestätigt: Jahresanspruch eingeben, Restbestand anzeigen, Urlaub/Arbeitszeit/HO planen,
Feiertage und Ferien anzeigen. Bestehenden Resturlaub einfach zu Beginn eintragen können.
Urlaubs-/Krankheitsunterlagen mit Bezugsdatum/-zeitraum, Einreichungsstatus und Einreichungsdatum.
Zunächst keine allgemeine Vertrags-/Abrechnungsablage und kein automatischer Versand.

Vorgeschlagenes Urlaubskonto:

- Jahresanspruch, Übertrag und datierte Korrekturen; alternativ Restbestand zu einem Stichtag.
- Status geplant, beantragt, genehmigt, abgelehnt, storniert, genommen.
- Gebucht = genehmigt oder genommen; denselben Tag beim Statuswechsel nur einmal zählen.
- Verfügbar = Anspruch + Übertrag + Korrekturen − gebucht.
- Geplant/beantragt separat vormerken, zusätzliche Vorschau nach Vormerkungen anzeigen.
- Stichtagsbestand ersetzt die davor liegende Kontohistorie; nicht nochmals vollen Anspruch addieren.
- Verbrauch nach geplanten Arbeitstagen, halbe Tage unterstützbar. Arbeitsfreie Tage/maßgebliche
  Feiertage nicht pauschal abziehen; Schulferien sind nur Kontext.
- Übertrag/Verfall/Vertragswechsel konfigurierbar; keine universellen Rechtsregeln behaupten.

## 5. Kalender und Planfreigabe

Bestätigt: Nutzer verwendet iCloud; Google ist spätere Kompatibilitätsoption.
iCloud darf bis zur nativen App warten, wenn frühe Serveranbindung ein Apple-ID-App-Passwort
verlangen würde. Keine Pflicht-Kalenderverbindung für die erste PWA.
Arbeitskalender erlaubt Überschneidungen, private Kalender erzeugen Konflikthinweise,
ignorierte Kalender beeinflussen nichts. Kein automatischer Arbeitszeitabzug.

Vorschlag: zuerst lesend, Schreiben offen. EventKit-Brücke auch schon auf macOS prüfen.
Explizit wählen, welche Kalenderdaten zum Backend gelangen; Aktualitätszeitpunkt anzeigen.
Offline-Geräte garantieren keine aktuelle Kalendersicht in der PWA.

Zeitplan gezielt an einzelne Konten freigeben und jederzeit widerrufen können.
Bestätigt: auch tatsächliche Arbeitszeiten und ausdrücklich als Urlaub erkennbare Abwesenheiten
müssen teilbar sein. Vorschlag: pro Empfänger getrennt wählen, ob Planung, Ist-Zeiten und Urlaub
sichtbar sind; nur lesender Zugriff. Standard bleibt privat.
Keine Diagnosen, Anhänge, privaten Termintitel oder Berichtshefte durch diese Freigabe teilen.
Kein öffentliches Nutzerverzeichnis voraussetzen.

## 6. Berichtsheft und KI

Bestätigt: digital. Texte/Bilder als Quellen; zunächst genügt kopierbarer Text zum Einfügen
ins offizielle IHK-Portal. Bestätigte Felder: Lernfeld, Zeit und Notizen.
Keine Portalautomatisierung nötig. Vorschlag: datierte Einträge mit diesen Feldern, nach Tag/Woche
gruppierbar. Exakte Gruppierung und Darstellung der Zeit können beim ersten Exportbeispiel geklärt werden.
Alte Berichtshefte liegen als PDFs vor; Archivimport vorsehen, strukturierte Übernahme separat prüfen.

PWA-KI erwünscht, falls unterstützter ChatGPT-/Anthropic-Login ohne eigenen API-Key möglich ist;
sonst lokale Apple-Modelle mit späterer Swift-App. Zusätzlich gewünschter Mac-Worker:
PWA lädt Quellen hoch, persönlicher Mac verarbeitet sie und liefert Entwurf zurück.

Vorschlag: OCR, Textgenerierung und Freigabe getrennt. Keine erfundenen Tätigkeiten; Unklarheiten
markieren. Freigegebene Texte nicht ungefragt ändern. Manuelle Nutzung funktioniert ohne KI.
Mac muss erreichbar und Modell verfügbar sein. Kein stiller Wechsel zur Cloud-KI.
Machbarkeit/Anbieterbedingungen siehe Architektur.

## 7. Import, Export und Erinnerungen

Bestätigt:

- CSV/XLSX hochladen, relevante Spalten visuell zuordnen. Beispieltabellen noch nicht verfügbar.
- Übersichtlicher Arbeitszeitexport als XLSX und PDF.
- Resturlaub/Anfangsstände auch manuell erfassen.
- In-App-Hinweise und Push, E-Mail optional.
- Offline nur bei vertretbarem Aufwand und zuverlässiger Umsetzung; keine Pflicht für Version 1.

Vorgeschlagener Import: Datei → Blatt/Kopfzeile → Spaltenzuordnung → Datums-/Zeit-/Zahlenformate
→ Vorschau mit Fehlern/Duplikaten → bestätigter Import. Zuordnungsvorlagen pro Nutzer speichern.
Excel-Zeitwerte, Dezimalstunden (7,7 ≠ 7:07), Tageswechsel und Summenzeilen unterscheiden.
Fehlende Angaben nicht erfinden. Importcharge nachvollziehbar und kontrolliert rücknehmbar.
Kein Import ohne Vorschau-Bestätigung; gleiche Datei erneut verursacht keine Doppelbuchungen.

Erinnerungen für laufende Timer, ungeprüfte Automatik, Berichtsheftlücken und Einreichungen.
Pro Kategorie abschaltbar, Ruhezeiten/Zeitzonen berücksichtigen. Push standardmäßig ohne sensible Details.
Bei fehlendem Netz keine erfolgreiche Speicherung vortäuschen. Kernbuchungen nicht von Push abhängig.

## 8. Spätere Funktionen und Plattformen

Selbstständigkeit: Kunden, Projekte, Tätigkeiten, abrechenbare Zeiten, Stundensätze und Auswertungen.
Rechnungsstellung noch kein festgelegter Umfang. Vordergrund-App-Tracking auf macOS zur Zuordnung
zu Projekten/Kunden gewünscht. Vorschlag: aktivierbar, zunächst lokal, mit Leerlauf-/Sperrzeiterkennung
und manueller Freigabe. Kein systemweites Vordergrund-App-Tracking in der PWA voraussetzen.

Reihenfolge: Backend/PWA/Shortcuts → macOS → iOS/iPadOS; watchOS gewünscht, genaue Einordnung offen.
Native Apps Swift/SwiftUI/Liquid Glass nach Apple HIG. Geräte laut Nutzer alle auf OS 27;
Hardware und Modellverfügbarkeit später prüfen. Kein bezahlter Apple-Developer-Account vorhanden.
MCP-Server mit OAuth für ChatGPT und Claude. Andere Clients können alternativ persönliche
Bearer-Tokens verwenden. Erster Toolumfang bleibt als Vorschlag in der Architektur dokumentiert.

Kontowiederherstellung beim Einrichten vom Nutzer wählbar: E-Mail-Codes, Rückfallpasswort oder
Recovery-Codes. Passkeys bleiben primäre Anmeldung. Vorschlag: mehrere Wiederherstellungswege
kombinierbar. E-Mail-Auswahl nur bei betriebsbereitem Mailversand und verifizierter Adresse;
ein Server ohne Mailversand bleibt mit den anderen Optionen vollständig nutzbar.

## 9. Noch offene Details

1. Berichtsheft-Gruppierung und Zeitdarstellung anhand eines Exportbeispiels prüfen; Felder stehen fest.
2. Erste MCP-Schreibaktionen: Vorschlag in Architektur; Zielclients und Authentifizierungswege stehen fest.
3. Ausbildungsstichtag, Pausenfenster und Urlaubs-/Vertragsparameter später im Onboarding.
4. Kalender-Schreibzugriff, strukturierter PDF-Import und Hardwaredetails später klären.

## 10. Abgrenzung

Kein PostgreSQL, Pflicht-Authentik oder Infrastrukturaufbau. Kein Pflicht-Offline-Sync,
Pflicht-KI-Abonnement oder Pflicht-Cloud-KI. Keine Team-Genehmigungshierarchie/Lohnabrechnung.
Konfigurierbare betriebliche Regeln sind keine Zusage allgemeiner rechtlicher Konformität.
