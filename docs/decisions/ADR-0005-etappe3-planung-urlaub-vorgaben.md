# ADR-0005: Etappe 3 – Planung und Urlaub: Nutzervorgaben und Paketplan

Status: akzeptiert. Nutzerentscheidungen vom 14.10.2026 (interaktive Rückfrage); Regeln darunter sind Lead-Annahmen und markiert.

## Nutzerentscheidungen

- Priorität nach Etappe 2: **Etappe 3 (Planung und Urlaub)** vor Berichtsheft/MCP und vor OIDC/Betrieb.
- Urlaub-Standardwerte für Onboarding und Tests: **30 Tage Jahresanspruch, 5-Tage-Woche**; Resturlaub und Stichtag trägt der Nutzer selbst ein.
- Berichtsheft: **kein IHK-Exportbeispiel vorhanden** – Standardformat (Datum, Lernfeld, Zeit, Notizen) wird gebaut, später anpassbar (Etappe 4).
- Geräteprüfung (Shortcuts, echte Passkeys): mit **eigener HTTPS-Testadresse**; der Nutzer nennt sie später. Bis dahin Compose/Anleitung
  vorbereiten, ohne Domain, TLS oder Reverse Proxy anzufassen (siehe `docs/SHORTCUTS.md` im PWA-Repo).

## Paketplan Etappe 3 (Annahmen, Verträge zuerst)

| ID | Paket | Verantwortung |
| --- | --- | --- |
| P3 | Vertrag v0.3.0 (Urlaubskonto, Abwesenheiten, Feiertage/Ferien, Planung, Planfreigaben, Export), ADR-Ergänzung | Claude-Lead |
| C8 | Urlaubskonto-Engine (reine Fachlogik wie `TimeEngine`: Anspruch, Übertrag, Stichtag, halbe Tage, genehmigt→genommen nicht doppelt) | Codex |
| C9 | Persistenz/REST für Abwesenheiten, Planung, Freigaben (Empfänger-/Umfangs-/Widerrufsprüfung), Feiertage Sachsen-Anhalt | Codex |
| L6 | PWA Urlaub/Planung/Kalenderansicht/Freigaben | Claude-Agent |
| L7 | XLSX/PDF-Export und Importvorschau (CSV/XLSX), Dateispeicher-Konfiguration | Claude-Agent bzw. Codex nach Aufwand |

Abnahme laut `UMSETZUNG.md` Abschnitt 3 (Restbestand nicht doppelt, Freigabewiderruf sperrt Abrufe, Importvorschau/Wiederholung ohne Duplikate,
Formelzellen sicher). Feiertags-/Ferienquelle: Daten fest eingebaut oder konfigurierbar, keine Online-Abfrage ohne Entscheidung (Annahme).

## Fachregeln Etappe 3a (Lead-Annahmen, binden C8/C9/L6)

- **Einheit**: halbe Tage als Ganzzahl (30 Tage = 60). Keine Fließkommazahlen.
- **Verbrauch** (`countedHalfDays`): je Kalendertag im Zeitraum, der Arbeitstag des an diesem Datum gültigen Arbeitsmodells ist und kein Feiertag der Region (eingebaut + eigene `holiday`), 2 halbe Tage;
  `halfDayStart` (erster Tag) bzw. `halfDayEnd` (letzter Tag) → 1; bei Eintagesabwesenheit mit einem der Flags → 1. Wochenenden/Nicht-Arbeitstage/Feiertage zählen 0. Schulferien sind nur Kontext.
- **Status**: `approved` und `taken` = gebucht (zählt einmal); `planned`/`requested` = geplant (separat, Vorschau `availableAfterPlanned`); `rejected`/`cancelled` zählen nie. Wechsel approved→taken ändert den Saldo nicht.
- **Saldo Jahr Y**: ohne Stichtag `available = Anspruch + Übertrag(manuell, Einstellung) + Korrekturen − gebucht`. Mit Stichtagsbestand S (Datum in Y): `available = S.remaining + Korrekturen ab S − gebucht ab S`
  (Anspruch/Übertrag des Jahres werden **nicht** zusätzlich addiert, Historie vor S ersetzt). Folgejahre normal. Kein anteiliger Anspruch im Eintrittsjahr (Annahme, später konfigurierbar).
  Übertragsverfall (`carryOverExpiry`): nach dem Datum werden noch nicht verbrauchte Übertragstage in der Vorschau ausgewiesen, aber nicht automatisch abgezogen (Annahme: rechtliche Regeln nicht erfunden).
- **Überlappung**: Abwesenheiten (alle Arten) dürfen sich nicht überlappen (409 `absence_overlap`); Krankheit und Urlaub am selben Tag werden nicht doppelt gutgeschrieben.
- **Tagesbewertung**: explizite Tagesmarkierung (Etappe 2) hat Vorrang; sonst setzt eine `approved/taken`-Urlaubs- bzw. `sick`-Abwesenheit die Markierung `vacation` bzw. `sick` (Soll 0), ein Feiertag an einem Arbeitstag `holiday`; halber Urlaubstag halbiert das Soll
  (neues optionales `targetOverrideSeconds` in `DayPreferences`). `planned/requested/other` ändern die Bewertung nicht.
- **Feiertage**: fest eingebaute Berechnung für Deutschland (bundesweit + Länder, Ostern gaußsch, Buß- und Bettag Sachsen), Region Standard `DE-ST`; keine Online-Abfrage. Eigene Feiertage/Schulferien als Zeiträume.
- **Freigaben**: nur lesend, getrennt je Scope plan/actual/vacation, standardmäßig nichts. Ansicht des Empfängers enthält keine Notizen, Orte, Segmente, Krankheit oder Unterlagen. Widerruf sofort wirksam (404).
  Kein Verzeichnis: Empfänger per `handle`; unbekannt → 404 `recipient_not_found` (Annahme, kleine Instanz). Freigaben berühren weder Berichtshefte noch Dokumente.
