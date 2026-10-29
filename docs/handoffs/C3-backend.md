# C3-backend – Abwesenheitssemantik, Zeitkonto ohne heutigen Tag, ICS, Konto-E-Mail = Recovery

Stand: 29.10.2026, Branch `c3-absence-semantics` (Basis main 182a933), nicht gemergt. Vertrag 0.36.0, ADR-0032 (Details dort).

## Geändert
1. **Abwesenheitsstatus je Art** (`AbsenceSemantics.swift`): Urlaub voller Ablauf; Krank/Freistellung `recorded`/`cancelled`; Sonstiges `planned`/`recorded`/`cancelled`. `status` im Input optional; Altwerte werden normalisiert (Antwort zeigt den gespeicherten Status), `recorded` bei Urlaub und `rejected` bei den anderen Arten sind 400 `absence_status_invalid_for_kind`. Migrationen `c3.allow_recorded_absence_status` (Check-Constraint, MariaDB-Zweig über `information_schema`, SQLite per Tabellenneubau wie C21) und `c3.normalise_absence_statuses` (Daten, `legacy_status`, Änderungsmarken). Import erzeugt `recorded` für Krank/Freigestellt, Duplikaterkennung kennt `recorded`. MCP `create_absence`: `status` optional, `recorded` erlaubt (Urlaub über MCP weiter nur planned/requested). Bilanzen: `recorded` zählt als gebucht.
2. **Zeitkonto ohne laufenden Tag**: `TimeEngine.accountBalance`, `AccountService.balance`, Wochen-Summary und Statistik zählen Tagesdifferenzen nur bis gestern; neue Felder `includesToday` (false) und `todayDeltaSeconds`. Anpassungen mit Datum heute zählen sofort. W4-Checkpoints unverändert gültig (liegen immer vor heute); Äquivalenztests grün.
3. **ICS**: Titel `Krank`/`Freigestellt`/`Abwesenheit` (nur Urlaub mit Statuszusatz); ausdrückliche Tagesmarkierungen (Urlaub, Krank, Freigestellt, Berufsschule) als ganztägige Termine unter `absences`; Berufsschultage unter `tracked`; Plan-Modi school/off waren schon sichtbar. Keine Notizen/Orte.
4. **Konto-E-Mail = Recovery-Mail**: siehe ADR-0032 Abschnitt 4; `PUT /me/recovery/email` ohne Body (204 sofort aktiv / 202 Code), alter Body abgebildet, 409 `recovery_email_must_be_account_email` / `account_email_missing`; `GET /me/recovery` mit `accountEmail`, `usesAccountEmail`; Profil-Adresswechsel/-Entfernen wirken auf die Wiederherstellung; Migration `c3.account_email_is_recovery_email` (verifizierte Konto-Adresse gewinnt; sonst wird eine verifizierte Recovery-Adresse übernommen; Reste gelöscht).

Doku: ADR-0032, ARCHITEKTUR, KONZEPT, `installation/ersteinrichtung.md`, CHANGELOG, STATUS, openapi (+ `contract-json.sh` gelaufen).

## Tests
Neu `Tests/TimetrackKitTests/AbsenceSemanticsTests.swift` (Matrix, REST je Art, Migration, Saldo/Woche/Statistik ohne heute, ICS, Recovery über Konto-Mail, Migration Recovery). Angepasst: Import-/Planungs-/Wochen-/Auth-Tests auf neue Semantik. Volllauf `swift test --build-system native --no-parallel`: 453 Tests, 42 übersprungen (MariaDB/Umgebung), 0 Fehler (Log geprüft, keine `error:`-Zeilen).

## Client-Änderungen nötig (nicht umgesetzt)
PWA und Apple (gleiche Stellen):
- Abwesenheitsformular: Statusauswahl nur bei Urlaub (Antrag/Genehmigung); bei Krank/Freistellung/Sonstiges keine Statusauswahl, `status` weglassen; Anzeige/Labels für `recorded` („erfasst“), keine „genommen/genehmigt“-Texte für Krank; Filter/Badges, Urlaubsantrag-Vorlage nur Urlaub.
- Unbekannten Status `recorded` tolerieren (Listen, Kalender, Woche `absences[].status`).
- Zeitkonto-Anzeige: Saldo ohne heute; `todayDeltaSeconds` getrennt zeigen („heute bisher ±…“), Wochenübersicht `summary.balanceSeconds/targetToDateSeconds` bedeuten jetzt „abgeschlossene Tage“; Statistik-Diagramm analog (`todayDeltaSeconds`).
- Einrichtung/Profil: Wiederherstellung per E-Mail ohne eigenes Adressfeld: Schalter nutzt die Konto-E-Mail (`GET /me/recovery` `email.accountEmail`; ohne bestätigte Adresse zuerst Profil-Adresse bestätigen lassen); `PUT /me/recovery/email` ohne Body; 204 = aktiv, 202 = Code eingeben (`/verify`).
- Texte Zeitkonto/ICS-Hinweise anpassen (Abo-Beschreibung).

## Nicht geprüft
MariaDB (Constraint-Austausch, Datenmigration, Recovery-Migration) wurde nicht gelaufen; nur SQLite. Revert von `c3.allow_recorded_absence_status` setzt `recorded` auf `approved`; Revert der Kind-Migration (excused) ist vorbestehend nicht verlustfrei.
