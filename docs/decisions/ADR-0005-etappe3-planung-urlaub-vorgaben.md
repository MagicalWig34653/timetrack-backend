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
