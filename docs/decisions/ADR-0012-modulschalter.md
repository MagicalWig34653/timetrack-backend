# ADR-0012: Abschaltbare Module (Server und Konto)

Status: akzeptiert. Nutzerentscheidung 15.10.2026: Funktionen wie das Berichtsheft sollen abschaltbar sein, **sowohl vom Betreiber (Admin) serverweit als auch je Konto**; schaltbar sind Berichtsheft, Urlaub und Planung, Import/Export samt Anhängen, Automatik/Shortcuts und MCP. Alles Weitere sind Lead-Annahmen.

## Module

| Schlüssel | Umfang | Immer an (Kern) |
| --- | --- | --- |
| `reports` | Berichtsheft: Lernfelder, Einträge, Wochen, Quellen, Textausgabe, MCP-Tools `get_report_*`/`*_report_entry`, Erinnerung `report_gap` | Konten, Anmeldung, Recovery, Zeittracking, Zeitkonto, Orte, Arbeitsmodelle, Hinweiszentrum, Einstellungen |
| `planning` | Urlaubskonto, Abwesenheiten, Kalender/Feiertage, Planung, Planfreigaben (ausgehend und eingehend), zugehörige MCP-Tools, Erinnerung `document_submission` | |
| `transfer` | Export (XLSX/PDF/CSV), Import (CSV/XLSX), Dateien/Anhänge und Speicher-Administration | |
| `automation` | Gerätetoken und `POST /automation/events` (Shortcuts), Vorschläge aus Automatik | |
| `mcp` | OAuth-Server (`/oauth/*`, Metadaten), persönliche Tokens, Grants, `/mcp` | |

## Regeln

- **Wirksam** (`effective`) = Server aktiviert **und** Konto aktiviert. Standard: alles aktiviert. Betreiber-Override per Umgebung `MODULES_DISABLED=reports,mcp` (kommagetrennt, nicht per UI umkehrbar, `lockedByOperator=true`).
- **Abgeschaltet heißt**: Routen liefern `404` mit Code `module_disabled`; die PWA blendet Navigation, Dashboard-Karten und Einstellungsseiten aus; MCP-`tools/list` führt die Tools nicht auf, `tools/call` liefert `isError` `module_disabled`; Hinweise der zugehörigen Kategorien werden nicht erzeugt (bestehende bleiben lesbar); neue Push-Nachrichten dafür entfallen.
- **Daten bleiben erhalten**; Wiedereinschalten stellt alles wieder her. Nichts wird gelöscht oder migriert.
- **Freigaben**: Ist `planning` beim Eigentümer aus, sind seine ausgehenden Freigaben unwirksam (Ansicht beim Empfänger 404), ohne sie zu löschen; ist es beim Empfänger aus, sieht er keine eingehenden.
- **Auswertung**: Ist `planning` aus, wirken Abwesenheiten und Feiertage **nicht** auf Tagesbewertung und Zeitkonto (als nutzte man das Modul nicht); manuell gesetzte Tagesmarkierungen bleiben. Annahme, im Admin- und Konto-UI mit Hinweis zu erklären.
- **Sicherheit**: Ist `mcp` oder `automation` für ein Konto aus, werden dessen Tokens/Grants sofort abgelehnt (401), nicht gelöscht. Serverweit aus: OAuth-/MCP-Routen und `.well-known`-Metadaten liefern 404.
- **API**: `GET /api/v1/modules` (Status je Modul für das eigene Konto), `PUT /api/v1/me/modules` (eigene Auswahl), `PUT /api/v1/admin/modules` (nur Admin, serverweit; Änderungen werden im Audit-Log festgehalten). Speicherung in der DB (`module_settings` serverweit, Konto-JSON in `account_settings`).
- Zugriffsprüfung zentral (ein Middleware-/Guard-Typ je Routengruppe), nicht pro Route verstreut; Tests je Modul: Server aus, Konto aus, beide an, Operator-Override, Tokens.

## Pakete

C20 Backend (Guard, Einstellungen, Admin-API, Hinweis-/MCP-Anbindung, Tests), L17 PWA (Ausblenden, Einstellungen, Admin-Seite, Erklärtexte), D1 Dokumentationsabgleich (parallel). Codex setzt C20 um.
