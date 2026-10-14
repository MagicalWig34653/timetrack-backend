# ADR-0006: Etappe 3b – Export, Import und Dateispeicher

Status: akzeptiert (Lead-Entscheidung 14.10.2026; Annahmen markiert). Vertrag: `contracts/openapi.yaml` v0.4.0.

## Entscheidungen (Annahmen, bindend für C11–C13 und L9)

- **Keine schweren Fremdbibliotheken**: ZIP über ZIPFoundation (MIT; im Package, auf Linux/macOS), XLSX/XML und PDF werden selbst erzeugt bzw. mit Foundation-`XMLParser` gelesen.
  PDF: eigener minimaler Writer (Seiten, Standard-Schrift Helvetica/WinAnsi für deutsche Umlaute, Tabellenlayout, Seitenumbruch, Kopf/Fuß). S3: eigener schlanker SigV4-Client (swift-crypto + AsyncHTTPClient, bereits transitiv).
  Keine neue Abhängigkeit ohne ADR.
- **Export** (`GET /api/v1/export/time?from&to&format=xlsx|pdf|csv`): Tageszeilen mit getrennten Spalten *tatsächlich* (Rohsummen, erster Beginn/letztes Ende) und *bewertet* (Rundungsdifferenzen, Pausenabzug, bewertete Zeit),
  Soll, Differenz, Markierung (Urlaub/Krank/Feiertag), laufender Tag als „vorläufig“; Summenzeile; Zeitraum höchstens 366 Tage; Kopf mit Name und Zeitraum, Fuß mit Erstellzeitpunkt. Spaltenüberschriften deutsch.
  CSV/XLSX-Zellen, die mit `=`, `+`, `-`, `@`, Tab oder CR beginnen und Text sind, werden als Text gekennzeichnet (Formelinjektion). Nur eigene Daten; keine Notizen von Freigaben.
- **Import** (CSV/XLSX → Segmente): Ablauf Upload → Blatt/Kopfzeile → Spaltenzuordnung (Datum, Beginn, Ende oder Dauer, optional Ort/Notiz/Art) → Formate (Datum `dd.MM.yyyy`/`yyyy-MM-dd`/Excel-Seriennummer; Zeit `HH:mm`, Excel-Zeitanteil, Dezimalstunden – **7,7 ≠ 7:07**)
  → Vorschau mit Zeilenfehlern/Duplikaten/Summenzeilen-Erkennung → bestätigter Commit (eine Transaktion, Importcharge). **Kein Import ohne Commit-Bestätigung.** Dieselbe Datei erneut: keine Duplikate (Schlüssel Konto+Beginn+Ende+Art; zusätzlich Dateihash je Charge gemerkt).
  Excel-Formelzellen werden nicht ausgewertet (nur zwischengespeicherte Werte gelesen; Zellen ohne Wert → Fehler), CSV-Werte nie als Formel interpretiert. Fehlende Angaben werden nicht erfunden. Charge kontrolliert rücknehmbar (nur unveränderte Segmente, sonst 409 listet Konflikte).
  Zuordnungsvorlagen pro Nutzer speicherbar. Grenzen: Datei ≤ 5 MiB, ≤ 20 000 Zeilen, ZIP-Bomben-Schutz (entpackte Größe/Anzahl Einträge begrenzt).
- **Dateispeicher**: Admin-Regeln (`/admin/storage`) in der DB: geordnete Liste `maxBytes → backend (db|s3|local)`, erste passende Regel gewinnt, letzte ohne Limit; S3-Zugangsdaten (Endpoint, Region, Bucket, Path-Style, Key-ID, Secret) und lokaler Pfad. Secret wird verschlüsselt/nur schreibend behandelt (nie in Antworten oder Logs);
  Verschlüsselung der gespeicherten Secrets mit einem Serverschlüssel aus `STORAGE_SECRET_KEY` (Env, base64 32 Byte; fehlt er, ist S3-Konfiguration abgelehnt). Je Datei werden Backend, Schlüssel, Größe, SHA-256, Eigentümer, Inhaltstyp gespeichert. **Regeländerung gilt nur für neue Uploads**, Bestandsdateien behalten ihren Speicherort;
  keine stille Umlagerung (Migration später als eigener Auftrag). Upload/Löschen mit Zuständen (`pending` → `stored`/`failed`) gegen Inkonsistenzen; Löschen entfernt Objekt nach DB-Commit mit Retry-Marker. Dateitypen-Whitelist (pdf, png, jpg, heic, txt), Inhalts-Sniffing, Größenlimit (Standard 10 MiB), Dateinamen-Sanitizing, lokale Pfade nur unterhalb des konfigurierten Wurzelverzeichnisses (keine Traversal, keine Symlinks hinaus).
- **Anhänge an Abwesenheiten** (z. B. Krankmeldung): `POST/GET/DELETE /absences/{id}/attachments`; Dokumente werden nie automatisch geteilt und erscheinen in keiner Freigabeansicht; Download nur durch den Eigentümer (404 sonst), `Content-Disposition: attachment`, `X-Content-Type-Options: nosniff`.
- Auth: Sitzung + CSRF wie überall; Admin-Endpunkte nur Rolle `admin`.

## Paketaufteilung

C11 Export-Engine + Endpunkt (XLSX/PDF/CSV), C12 Import-Engine + Endpunkte, C13 Dateispeicher + Admin-Regeln + Anhänge, L9 PWA (Export-, Import-, Speicher-, Anhang-UI) gegen Mock. Gemeinsame Dateien (Package.swift, Routes, Configure) sind bereits verdrahtet: jedes Paket besitzt nur seinen Ordner
(`Sources/TimetrackKit/Export|Import|Storage/`) und seine Tests; Migrationen nur in `ImportSchema`/`StorageSchema`.
