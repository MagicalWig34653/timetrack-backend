# Timetrack – Produktkonzept

Anforderungen Stand 13.10.2026 (bestätigt), Umsetzungsvermerke Stand 17.10.2026. Bestätigt = Nutzervorgabe;
Vorschlag = fachliche Ausarbeitung, noch nicht ausdrücklich bestätigt; Details der Umsetzung stehen in den ADRs und
sind dort teils Lead-Annahmen. Die Anforderungen selbst sind unverändert; neu sind nur die Vermerke
„Umsetzungsstand“ je Abschnitt. Maßgeblich für geprüfte Zustände ist [STATUS.md](STATUS.md).
Technik: [Architektur](ARCHITEKTUR.md). Umsetzung: [Etappen](UMSETZUNG.md).

Statusbegriffe: **umgesetzt** = im Backend (und der PWA) vorhanden und automatisiert getestet, nicht auf Echtgeräten
geprüft, sofern nicht anders vermerkt; **teilweise** = Teile vorhanden; **geplant** = noch nicht begonnen.

## 1. Ziel und Nutzerkreis – bestätigt

Selbst hostbare Zeittracking-Lösung unter AGPLv3, mit Backend, PWA und später Apple-Apps.
Mehrere getrennte Konten pro Server von Beginn an. Registrierung nur mit Token/Einladungslink.
Nutzer sehen gegenseitig keine privaten Daten. Zeitplanfreigaben für ausgewählte Nutzer derselben
Instanz sind möglich. Keine Team-Genehmigungshierarchie im ersten Umfang.

Der Nutzer ist Auszubildender mit anschließender Anstellung; Historie und Berichtshefte bleiben erhalten. Selbstständigenfunktionen dürfen später kommen.
Die Umsetzung übernimmt Claude Code. Fragen gesammelt im normalen Chat, nicht interaktiv stellen.

Umsetzungsstand: **umgesetzt** – Mehrkonten mit strikter Trennung, Registrierung nur per Einladung (auch bei OIDC),
private Daten, Planfreigaben (siehe Abschnitt 5); keine Team-Genehmigungshierarchie. Historie bleibt über versionierte
Arbeitsmodelle erhalten. Eigene Selbstständigenfunktionen: **geplant** (Abschnitt 8).

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

Umsetzungsstand: **umgesetzt** (ADR-0004, ADR-0005) – Soll täglich oder wöchentlich, Modelle mit `validFrom` ohne Rückwirkung,
Schulregel mit Schwelle und Gutschrift (Standard 4 × 45 min, 7:42), Fahrtzeiten als Arbeit konfigurierbar, Zeitkonto mit
Anfangsstand und datierten Korrekturen, Feiertage für alle 16 Bundesländer. **Teilweise**: `arbzg-adult-de` und
`jarbschg-minor-de` (R2, ADR-0028) im Backend-Worktree; fachliche Prüfung und Client-Anzeige offen. Geführtes Onboarding (Ausbildungsstichtag u. Ä.) **umgesetzt als PWA-Assistent** (P1, ADR-0019; Lead-Prüfung offen): Arbeitsmodell, Pausenfenster, Schule, Urlaub (Stichtagsbestand statt anteiligem Anspruch), Module, Zusammenfassung; Vorschläge werden erst nach Bestätigung gespeichert.

X3: Anfangsstand und Korrekturen sind mit Grund, Betrag und Erstellungszeit abrufbar und einzeln löschbar. Nach dem Löschen gilt der neu berechnete Saldo; ein gelöschter Anfangsstand kann neu angelegt werden. Die Markierung `needsReview` eines Zeitabschnitts wird bei einer Ende-Korrektur, bei Annahme oder Ablehnung seines Ende-Vorschlags oder durch ausdrückliche Quittierung entfernt. Jede Änderung am Abschnitt wird als Revision festgehalten.

Vorschlag: Wochen-Soll mit Verteilung auf Arbeitstage oder explizite Tages-Sollwerte, klare
Vorrangregel. Bei reinem Wochen-Soll braucht die Abwesenheitsbewertung eine definierte Tagesbasis.
Änderungen ab Stichtag, rückwirkende Neubewertung ausdrücklich wählen. Keine doppelte Gutschrift
bei Überschneidungen von Schule, Feiertag, Urlaub und Krankheit.

Umsetzungsstand der Vorschläge: Wochen-Soll wird gleichmäßig auf Arbeitstage verteilt oder durch Tageswerte überschrieben,
Änderungen gelten ab `validFrom`, je Tag höchstens eine Markierung (ADR-0004, Lead-Annahmen). Eine wählbare
rückwirkende Neubewertung ist nicht vorgesehen.

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

Umsetzungsstand: **umgesetzt** (ADR-0004 mit Zusatz C7; W3: stornierte Abschnitte einsehen, wiederherstellen und endgültig löschen, Statistikreihe für Diagramme; W2: beendeten letzten Abschnitt wieder öffnen, „Timer fortsetzen“) – Timer, manuelle Segmente mit Revisionen, idempotenter Timer,
Rundung nur an den äußersten Tagesgrenzen, Roh-/korrigierte/bewertete Zeit getrennt, Nachtschicht gehört zum Tag des Beginns,
Automatik per Gerätetoken je Ort `direct`/`suggest`/`off` mit Vorbeifahrtschutz (Standard 300 s Bestätigung, Rückdatierung auf
Ankunft). **Nicht auf Echtgeräten geprüft**: Shortcuts mit echter Standortauslösung. Ein globaler Schalter für die Automatik ist
als Modul `automation` **umgesetzt** (ADR-0012, C20/L17); zusätzlich je Ort `off` bzw. Gerätetoken widerrufen.
W1 (ADR-0027, **umgesetzt**): Ein Abgangsereignis beendet auch einen manuell oder anderweitig gestarteten laufenden Timer (Modus `direct` zur Ereigniszeit, `suggest` als Vorschlag, `off` nie; Vorbeifahrt bucht nichts). Für Werkzeuge ohne POST/Header gibt es pro Konto Auslöse-Links (`GET /t/<geheimes-token>/start|stop|toggle`, widerrufbar, optional an einen Ort gebunden); Nutzeranforderung, Sicherheitsabwägung in ADR-0027 und `ARCHITEKTUR.md` Abschnitt 5.

Pausenvorlagen nur innerhalb aktiver Arbeitszeit anwenden, Überschneidungen nicht doppelt abziehen.
Eine übersprungene Pause bleibt als tatsächliche Arbeit erfasst. Keine Pause zur vermeintlichen
Rechtskonformität erfinden. Regelbasierte Hinweise sind keine verbindliche Rechtsprüfung.

Standardprofil Erwachsene/Deutschland nach § 4 ArbZG: grundsätzlich 30 Minuten Pause bei mehr
als sechs bis neun Arbeitsstunden, darüber 45 Minuten; Teilpausen mindestens 15 Minuten und
keine Arbeit länger als sechs Stunden ohne Pause. Quellenstand/Rechtsprofil anzeigen und vor
Implementierung fachlich validieren. Jugendliche und Sonderfälle brauchen eigene geprüfte Regeln.
Quelle: https://www.gesetze-im-internet.de/arbzg/__4.html

Umsetzungsstand: **umgesetzt** als reine Hinweise (`breakHints`, Profil `arbzg-adult-de`) auf tatsächlichen Zeiten; feste
Pausenvorlagen überspringbar. R2 ergänzt Jugendprofil und `legalWarnings` (ADR-0028).
Fachliche Validierung durch eine fachkundige Person steht aus; keine Rechtsberatung. Sonderfälle bleiben offen.

## 4. Urlaub, Abwesenheit und Planung

Bestätigt: Jahresanspruch eingeben, Restbestand anzeigen, Urlaub/Arbeitszeit/HO planen,
Feiertage und Ferien anzeigen. Bestehenden Resturlaub einfach zu Beginn eintragen können.
Urlaubs-/Krankheitsunterlagen mit Bezugsdatum/-zeitraum, Einreichungsstatus und Einreichungsdatum.
Zunächst keine allgemeine Vertrags-/Abrechnungsablage und kein automatischer Versand.

Umsetzungsstand: **umgesetzt** (ADR-0005, Stufe 3a) – Urlaubskonto in halben Tagen, Übertrag, Korrekturen, Stichtagsbestand,
Statusfolge, Vorschau, Abwesenheiten mit Anhängen und Einreichungsstatus, Planung (Arbeit/HO), Feiertage. Schulferien nur als
vom Nutzer erfasste Zeiträume (keine eingebauten Ferientermine). Anspruch 30 Tage/5-Tage-Woche sind Standardwerte für
Onboarding und Tests, keine Nutzerdaten. Übertrag/Verfall konfigurierbar im Rahmen des ADR; keine Rechtsbehauptung.

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

Umsetzungsstand Kalender: **geplant** (Etappe 5/6). Der Kalender in der PWA zeigt Feiertage, Abwesenheiten und Planung des
Kontos; es gibt keine Kalenderanbindung (iCloud, Google, EventKit).

Zeitplan gezielt an einzelne Konten freigeben und jederzeit widerrufen können.
Bestätigt: auch tatsächliche Arbeitszeiten und ausdrücklich als Urlaub erkennbare Abwesenheiten
müssen teilbar sein. Vorschlag: pro Empfänger getrennt wählen, ob Planung, Ist-Zeiten und Urlaub
sichtbar sind; nur lesender Zugriff. Standard bleibt privat.
Keine Diagnosen, Anhänge, privaten Termintitel oder Berichtshefte durch diese Freigabe teilen.
Kein öffentliches Nutzerverzeichnis voraussetzen.

Umsetzungsstand Planfreigabe: **umgesetzt** – Freigabe je Empfänger (Kontokennung) mit getrennten Umfängen für Planung,
Ist-Zeiten und Urlaub, nur lesend, jederzeit widerrufbar, Standard privat; Ist-Zeiten nur als bewertete Beginn/Ende/Dauer ohne
Orte und Notizen; Anhänge und Berichtsheft nie geteilt (ADR-0005, `contracts/openapi.yaml`).

## 6. Berichtsheft und KI

Bestätigt: digital. Texte/Bilder als Quellen; zunächst genügt kopierbarer Text zum Einfügen
ins offizielle IHK-Portal. Bestätigte Felder: Lernfeld, Zeit und Notizen.
Keine Portalautomatisierung nötig. Vorschlag: datierte Einträge mit diesen Feldern, nach Tag/Woche
gruppierbar. Exakte Gruppierung und Darstellung der Zeit können beim ersten Exportbeispiel geklärt werden.
Alte Berichtshefte liegen als PDFs vor; Archivimport vorsehen, strukturierte Übernahme separat prüfen.

Umsetzungsstand: **umgesetzt** (ADR-0008, ohne KI) – Lernfeldliste, datierte Einträge (Lernfeld, Zeit, Notiz), Wochenansicht
mit Status, Quellen (Notizen/Dateien), kopierbarer Text im **Standardformat** (Ausgabeprofil `standard`); Berichtsheft bleibt
privat. **Teilweise**: Alt-PDFs nur als Archivdatei im Dateispeicher ablegbar; strukturierte Übernahme **geplant**.
Das Ausgabeformat ist **angenommen**, nicht gegen ein echtes IHK-Beispiel validiert (siehe Abschnitt 9).

PWA-KI erwünscht, falls unterstützter ChatGPT-/Anthropic-Login ohne eigenen API-Key möglich ist;
sonst lokale Apple-Modelle mit späterer Swift-App. Zusätzlich gewünschter Mac-Worker:
PWA lädt Quellen hoch, persönlicher Mac verarbeitet sie und liefert Entwurf zurück.

Vorschlag: OCR, Textgenerierung und Freigabe getrennt. Keine erfundenen Tätigkeiten; Unklarheiten
markieren. Freigegebene Texte nicht ungefragt ändern. Manuelle Nutzung funktioniert ohne KI.
Mac muss erreichbar und Modell verfügbar sein. Kein stiller Wechsel zur Cloud-KI.
Machbarkeit/Anbieterbedingungen siehe Architektur.

Umsetzungsstand KI: **geplant** (Etappe 5/6): kein KI-Entwurf, kein Mac-Worker, kein Anbieterzugang. Im Backend ist dafür
nichts vorhanden; das Berichtsheft kennt nur Einträge, die der Nutzer selbst anlegt. Über MCP können externe Assistenten
Einträge lesen/anlegen (Abschnitt 8), das ist kein eingebauter KI-Zugang.

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

Umsetzungsstand: **umgesetzt** – Export XLSX/PDF/CSV (eigene Writer, `tatsächlich` und `bewertet` getrennt), Import
CSV/XLSX mit Spaltenzuordnung, Vorschau, Commit, Rücknahme und Vorlagen (ADR-0006); Hinweise (Timer, Vorschläge,
Berichtslücke, Einreichung), Ruhezeiten und Web Push mit generischer Nutzlast (ADR-0010). **Teilweise geprüft**: Push nur gegen
Fake-Dienst, Exporte nicht in Excel/Viewer geöffnet, E-Mail als Hinweiskanal **geplant** (nur Recovery-Mails). Offline-Schreiben:
bewusst nicht vorhanden (die PWA zeigt Offline-Hinweis, speichert nichts vor).

## 8. Spätere Funktionen und Plattformen

Selbstständigkeit: Kunden, Projekte, Tätigkeiten, abrechenbare Zeiten, Stundensätze und Auswertungen.
Rechnungsstellung noch kein festgelegter Umfang. Vordergrund-App-Tracking auf macOS zur Zuordnung
zu Projekten/Kunden gewünscht. Vorschlag: aktivierbar, zunächst lokal, mit Leerlauf-/Sperrzeiterkennung
und manueller Freigabe. Kein systemweites Vordergrund-App-Tracking in der PWA voraussetzen.

Reihenfolge: Backend/PWA/Shortcuts → macOS → iOS/iPadOS; watchOS gewünscht, genaue Einordnung offen.
Native Apps Swift/SwiftUI/Liquid Glass nach Apple HIG. Geräte laut Nutzer alle auf OS 27;
Hardware und Modellverfügbarkeit später prüfen. Ein bezahlter Apple-Developer-Account ist inzwischen vorhanden (16.10.2026); Associated Domains (Voraussetzung für Passkeys) und App Groups sind damit möglich (ADR-0015); die Passkey-Anmeldung in den Apps ist noch nicht auf einem Gerät erprobt.
MCP-Server mit OAuth für ChatGPT und Claude. Andere Clients können alternativ persönliche
Bearer-Tokens verwenden. Erster Toolumfang bleibt als Vorschlag in der Architektur dokumentiert.

Umsetzungsstand Abschnitt 8: Selbstständigkeit und App-Tracking: **geplant**. Native Apps (macOS, iOS/iPadOS, watchOS inkl. Komplikation und Widgets): **implementiert** (A1–A8, Repo timetrack-apple), Geräteprüfung und TestFlight-Upload **offen**; Kalenderbrücke, KI-Worker und Standortautomatik der Apps **geplant**. Konto-Darstellung (Akzent, Farbschema): **umgesetzt** (P2, ADR-0020). Kontenverwaltung, Selbstauskunft und Selbstlöschung: **umgesetzt** (B1, ADR-0016).
MCP: **umgesetzt** (ADR-0009) – `/mcp` mit 22 Tools nach Scope, OAuth-Server (Dynamic Client Registration, PKCE, Refresh-Rotation),
persönliche Tokens, Grants; Anbindung in echtem ChatGPT/Claude **nicht geprüft** (`MCP.md`).
Profil (Anzeigename, E-Mail-Adresse mit Bestätigungscode, Handle nur lesend): **umgesetzt** (P1, ADR-0019; Lead-Prüfung offen).

Kontowiederherstellung: **umgesetzt** – Recovery-Codes, Rückfallpasswort (Argon2id), E-Mail-Code (nur bei konfiguriertem SMTP;
real nur gegen Mailpit/Fake geprüft), kombinierbar.

Kontowiederherstellung beim Einrichten vom Nutzer wählbar: E-Mail-Codes, Rückfallpasswort oder
Recovery-Codes. Passkeys bleiben primäre Anmeldung. Vorschlag: mehrere Wiederherstellungswege
kombinierbar. E-Mail-Auswahl nur bei betriebsbereitem Mailversand und verifizierter Adresse;
ein Server ohne Mailversand bleibt mit den anderen Optionen vollständig nutzbar.

## 9. Noch offene Details

Stand 17.10.2026. Erledigtes ist vermerkt, nicht gelöscht; offen bleibt, was nicht durch Nutzerentscheidung geklärt ist.

1. Berichtsheft-Gruppierung und Zeitdarstellung anhand eines Exportbeispiels prüfen; Felder stehen fest.
   **Weiterhin offen**: Es liegt kein IHK-Beispiel vor; umgesetzt ist das angenommene Standardformat (ADR-0008,
   Nutzerentscheidung 14.10.), später als weiteres Ausgabeprofil anpassbar.
2. Erste MCP-Schreibaktionen: Vorschlag in Architektur; Zielclients und Authentifizierungswege stehen fest.
   **Entschieden und umgesetzt** (ADR-0009, Lead-Entscheidung): `start_timer`, `stop_timer`, `create_segment`, `correct_segment`,
   `create_absence` (nur geplant/beantragt), `set_plan_day`, `create_report_entry`, `update_report_entry`; keine Lösch-, Admin-,
   Freigabe-, Token- oder Speicher-Tools. Praxis im echten Connector steht aus.
3. Ausbildungsstichtag, Pausenfenster und Urlaubs-/Vertragsparameter später im Onboarding. **Weiterhin offen**
   (Onboarding seit P1 umgesetzt, ADR-0019; ob die Schritte und Vorschläge dem Nutzer genügen, ist nicht bestätigt. Anteiliger Urlaub im Eintrittsjahr bleibt bewusst aus, stattdessen Stichtagsbestand.)
4. Kalender-Schreibzugriff, strukturierter PDF-Import und Hardwaredetails später klären. **Weiterhin offen.**
5. Neu (15.10.2026, Nutzerentscheidung): Module sind durch Betreiber und je Konto abschaltbar (ADR-0012, Vertrag v0.9.0);
   Umgesetzt (C20/L17, 16.10.). Annahmen dazu (z. B. Wirkung auf Zeitkonto bei abgeschaltetem Modul `planning`) sind im ADR
   als Lead-Annahmen markiert.
6. Rechtsprofil: Jugendprofil R2 im Backend-Worktree umgesetzt (ADR-0028); Sonderfälle, Client-Anzeige und fachliche Validierung stehen aus.

## 10. Abgrenzung

Kein PostgreSQL, Pflicht-Authentik oder Infrastrukturaufbau. Kein Pflicht-Offline-Sync,
Pflicht-KI-Abonnement oder Pflicht-Cloud-KI. Keine Team-Genehmigungshierarchie/Lohnabrechnung.
Konfigurierbare betriebliche Regeln sind keine Zusage allgemeiner rechtlicher Konformität.


## Kalenderanbindung (Entscheidung 17.10.2026)

Die Anbindung an Kalender (Apple-Kalender, EventKit) erfolgt **nur über die native App** auf dem Gerät, ohne Server-Zugriff auf Kalenderkonten und damit ohne App-spezifische Passwörter. Das Backend bleibt kalenderfrei. Umsetzung: späteres Paket der Apple-Apps (Opt-in, Standard: lesen; Schreiben nur nach eigener Entscheidung; private Titel werden nicht geteilt).

Umsetzungsstand Wochenplanung (K1, ADR-0021): **umgesetzt** – Plantage tragen optional geplante Zeiten (Beginn, Ende, Pause) und die PWA bietet Wochenplaner und Wochenübersicht; Native Apps folgen in einem späteren Paket. Offen: Plan/Ist-Hinweise, Nachtschichten über Mitternacht (bewusst nicht unterstützt).
