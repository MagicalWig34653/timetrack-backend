# ADR-0026: Vorlage für den Urlaubsantrag je Konto

Status: Umsetzungsentscheidung von Paket B7 (Backend; Gegenstück zu PWA-Paket P6); Lead-Prüfung offen.

## Kontext

Die PWA füllt das Antragsformular des Arbeitgebers (PDF) aus Urlaubskonto und Abwesenheit aus. Bisher lag die Vorlage nur im Browser (IndexedDB). Sie soll geräteübergreifend am Konto hängen.

## Entscheidungen

1. **Genau eine Vorlage je Konto**, privat, ohne Freigabe. Tabelle `vacation_request_forms` (`account_id` eindeutig, `file_id`, `mapping` als JSON-Text, `updated_at`); Migration `b7.create_vacation_request_forms`. Kein Fremdschlüssel auf `stored_files` (Löschung der Datei wird wiederholbar abgewickelt, wie bei Anhängen).
2. **Datei im bestehenden Dateispeicher**: Das PDF ist ein normaler `stored_files`-Eintrag und folgt den Speicherregeln (DB, S3, lokal) samt Prüfsumme, Zwei-Phasen-Schreiben und Aufräumjob. Beim Ersetzen wird die alte Datei nach dem Umhängen entfernt; die Zuordnung bleibt erhalten (die PWA setzt sie bei Bedarf selbst zurück).
3. **Grenzen**: PDF höchstens 5 MB (413 `file_too_large`, vor dem Puffern per Content-Length und `collect(max:)`), Magic Number `%PDF-` (sonst 400 `bad_request`), Content-Type `application/pdf` (sonst 415 `unsupported_type`). Zuordnung: JSON-Objekt, undurchsichtig, höchstens 64 KB (413 `mapping_too_large`); Arrays oder kein JSON 400. Ohne Vorlage 409 `no_template`. `X-File-Name` prozent-kodiert, Standard `Urlaubsantrag.pdf`, Endung `.pdf` wird ergänzt, Name wie bei Uploads bereinigt.
4. **Eine Quote je Konto gibt es nicht**; die Datei zählt wie jede Datei gegen die Speicherregeln und das Admin-Upload-Limit (`maxUploadBytes`, 413, falls kleiner als 5 MB).
5. **Download** `GET .../file`: `application/pdf`, `Content-Disposition: attachment` (RFC 5987), `nosniff`, `private, no-store`; fremde oder fehlende Vorlage 404.
6. **Kontoexport**: `vacation-request-form.json` (Dateiname, Größe, Zuordnung, Zeitpunkt) und das PDF unter `files/`; Eintrag `vacation-request-form` in den Zählern des Manifests.
7. **Kontolöschung**: Tabelle in `AccountEraser.wipes`; die Datei wird wie alle Dateien des Kontos über den Dateidienst entfernt. Der Vollständigkeitstest (`testB1EraserCoversEveryAccountTable`) deckt die Tabelle ab.
8. **Modul** `planning` über das Präfix `/vacation`; Sitzung und CSRF wie die übrigen Routen. Kein MCP-Werkzeug.
9. Vertrag v0.25.0 (additiv; Schemawechsel durch neue Tabelle).

## Offen

- Kein Audit-Eintrag und keine Versionierung der Vorlage (letzter Stand gewinnt).
- PDF-Inhalt wird nur auf die Magic Number geprüft, nicht auf Gültigkeit oder aktive Inhalte; Auslieferung ausschließlich als attachment.
