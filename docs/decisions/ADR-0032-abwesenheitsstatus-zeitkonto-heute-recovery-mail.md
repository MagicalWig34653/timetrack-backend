# ADR-0032: Abwesenheitsstatus je Art, Zeitkonto ohne laufenden Tag, Konto-E-Mail als Recovery-Adresse (C3)

Status: umgesetzt im Branch `c3-absence-semantics`; Lead-Prüfung offen. Vertrag 0.36.0.

Auslöser sind vier Rückmeldungen der Nutzerin: „Krank kann man nicht ‚nehmen‘ oder beantragen“ (auch bei den anderen Abwesenheiten prüfen), „Zeitkonto jetzigen Tag nicht einberechnen“, „Freigestellt usw. fehlt in ICS“ und „Kontomail = Recovery-Mail“.

## 1. Abwesenheitsstatus je Art

Der Antragsablauf (`planned`, `requested`, `approved`, `rejected`, `cancelled`, `taken`) ergibt nur beim Urlaub Sinn: Er verbraucht Urlaubskonto und braucht eine Entscheidung des Arbeitgebers. Krankheit tritt ein, eine Freistellung ordnet der Arbeitgeber an, beides wird weder beantragt noch genehmigt. Neu ist deshalb der neutrale Status `recorded` („erfasst“).

| Art | gespeicherte Status | Bedeutung |
| --- | --- | --- |
| `vacation` | planned, requested, approved, rejected, cancelled, taken | voller Ablauf (unverändert) |
| `sick` | recorded, cancelled | wird erfasst, wenn es passiert (auch ein Attest für kommende Tage); `cancelled` = Eintrag zurückgenommen |
| `excused` (Freistellung) | recorded, cancelled | vom Arbeitgeber angeordnet, kein Antrag |
| `other` | planned, recorded, cancelled | Sonderurlaub, Arzttermin, Umzug u. a.: reiner Eintrag ohne Wirkung auf Soll oder Urlaubskonto, daher keine Genehmigung in der App; eine Zusage des Arbeitgebers gehört in die Notiz |
| Berufsschultage | – (keine Abwesenheitsart) | Plantag-Modus `school`, Tagesmarkierung `school_credit` oder Schulabschnitte; kein Status |
| Feiertage, Betriebstage | – | Kalender, kein Status |

`recorded` zählt wie `approved`/`taken` als gebucht (`isBooked`): Krankheit und Freistellung wirken sofort auf die Tagesmarkierung, auch wenn der Eintrag früher nur „geplant“ oder „beantragt“ war. `other` bleibt wie bisher ohne Tageswirkung.

### Validierung und Rückwärtskompatibilität

- `AbsenceInput.status` ist jetzt optional. Standard: `planned` bei Urlaub, sonst `recorded`.
- Ältere Clients senden den Urlaubsablauf auch für andere Arten. Das wird angenommen und normalisiert (`AbsenceSemantics.normalise`): sick/excused planned, requested, approved, taken wird `recorded`; other requested wird `planned`, approved/taken wird `recorded`. Die Antwort enthält den gespeicherten Status.
- 400 `absence_status_invalid_for_kind`: `recorded` bei Urlaub, `rejected` bei sick/excused/other (ohne Antrag gibt es nichts abzulehnen). Neue Clients sollen nur die Tabellenwerte senden.
- Migration `c3.allow_recorded_absence_status` erweitert die Status-Prüfbedingung (MariaDB und SQLite). `c3.normalise_absence_statuses` normalisiert bestehende Zeilen (sick/excused: planned/requested/approved/taken zu recorded, rejected zu cancelled; other: requested zu planned, approved/taken zu recorded, rejected zu cancelled), der frühere Status bleibt in `absences.legacy_status`, die Änderungsmarken der betroffenen Konten werden erhöht (Kontostand-Zwischenstände, W4). Vorher als „geplant/beantragt“ geführte Krankheitstage zählen damit als Krankheitstage; das ist gewollt.
- Import der Arbeitszeit-Tabelle erzeugt für Krank/Freigestellt `recorded` statt taken/approved. MCP `create_absence`: `status` optional und `recorded` erlaubt; für Urlaub über MCP weiter nur planned/requested.
- ICS: Titel ohne Statuszusatz für Krank (`Krank`), Freistellung (`Freigestellt`), Sonstiges (`Abwesenheit`); nur Urlaub trägt den Antragsstatus.

## 2. Zeitkonto ohne den laufenden Tag

Der laufende Tag hat sein volles Soll, aber erst einen Teil des Ist; der Saldo fiel deshalb morgens und stieg im Lauf des Tages. Festlegung: Der Saldo zählt die Tagesdifferenzen bis **gestern** (in der Zeitzone des jüngsten Arbeitsmodells), Soll und Ist von heute fehlen vollständig. Der heutige Wert steht getrennt:

- `TimeAccount.includesToday` (immer `false`) und `todayDeltaSeconds` (Ist + Gutschrift - Soll des heutigen Tages; `null`, wenn `asOf` vor heute liegt oder das Konto noch nicht begonnen hat). `asOf` bleibt das angefragte Datum (höchstens heute).
- Dasselbe an `TimeWeek.summary` (dort enthalten `balanceSeconds` und `targetToDateSeconds` heute nicht mehr; die Tageszeilen der Woche zeigen `balanceSeconds` von heute weiter an) und an `TimeStatistics` (Differenzen, Soll-bis-heute und kumulierter Saldo ohne heute).
- Kontoanpassungen (Korrektur, Anfangsstand) mit Datum heute zählen sofort: Sie sind ausdrückliche Einträge, keine laufende Größe.
- Die Zwischenstände je Monatsende (W4) liegen immer vor heute und sind unverändert gültig; Äquivalenztests prüfen weiter Fenster gegen Gesamtauswertung.

## 3. ICS-Abo

`absences` enthält zusätzlich ausdrückliche Tagesmarkierungen (Urlaub, Krank, Freigestellt, Berufsschultag; zusammenhängende Tage zu einem Termin), soweit kein Abwesenheitseintrag den Tag schon zeigt. `tracked` zeigt Berufsschultage (Markierung `school_credit` oder Schulabschnitte) als eigenen Termin „Berufsschule“. `plan` zeigte Modus `school` und `off` bereits („Plan: Berufsschule“, „Plan: Frei“). Ganztägig, ohne Notiz und Ort. Das Fenster der Tagesmarkierungen reicht wie die übrigen Inhalte bis 400 Tage voraus. Einen Plan-Modus „freigestellt“ gibt es nicht; Freistellung ist eine Abwesenheitsart bzw. Tagesmarkierung.

## 4. Konto-E-Mail ist die Recovery-Adresse

Die Konto-E-Mail (Profil, mit Bestätigungscode) ist die einzige Adresse für Wiederherstellungscodes. Die Tabelle `email_recovery` bleibt, trägt aber nur noch den Schalter „E-Mail-Wiederherstellung ist eingeschaltet“ (`active`); die Adresse im Datensatz folgt der Konto-E-Mail.

- `PUT /me/recovery/email` ohne Body: bei bestätigter Konto-E-Mail sofort aktiv (204), sonst Code an die Konto-E-Mail (202) und Bestätigung per `/me/recovery/email/verify` (bestätigt dann auch die Konto-E-Mail). Der alte Body `{email}` ist veraltet, bleibt aber lauffähig: gleich der bestätigten Konto-E-Mail ergibt den alten Zweischritt (202, Code); fehlt oder ist unbestätigt die Konto-E-Mail, wird die angegebene Adresse nach Code-Bestätigung zur Konto-E-Mail (kein zweiter Datensatz); eine abweichende Adresse bei bestätigter Konto-E-Mail ist 409 `recovery_email_must_be_account_email`. Ohne Konto-E-Mail und ohne Body 409 `account_email_missing`.
- `recoveryStart`/`recoveryComplete` mit Methode `email` verwenden die bestätigte Konto-E-Mail; eine Änderung der Adresse macht offene Codes unwirksam (Beweis ist der Hash der Adresse). Adresswechsel im Profil führt eine aktive E-Mail-Wiederherstellung auf die neue Adresse; Entfernen der Konto-E-Mail schaltet sie ab.
- `GET /me/recovery`: `email.verified` meint die Konto-E-Mail; neu `accountEmail` und `usesAccountEmail` (immer true).
- Migration `c3.account_email_is_recovery_email`: Ist die Konto-E-Mail bestätigt, bleibt eine aktive, bestätigte Recovery-Einstellung bestehen und zeigt auf die Konto-E-Mail, die getrennte Adresse entfällt (nicht aktive oder unbestätigte Reste werden gelöscht). Ist die Konto-E-Mail unbestätigt oder fehlt sie und die Recovery-Adresse ist bestätigt, wird die Recovery-Adresse zur bestätigten Konto-E-Mail (außer ein anderes Konto hat sie schon bestätigt; dann entfällt sie).

## Folgen für Clients

Siehe `docs/handoffs/C3-backend.md`.
