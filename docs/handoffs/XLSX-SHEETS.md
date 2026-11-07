# XLSX-SHEETS: Blattgrenze und einmaliges Paket-Parsen beim Import

Stand 07.11.2026, Branch `xlsx-sheet-limit`.

## Befund

`WorkbookDelegate` sammelte alle `<sheet>`-Elemente aus `xl/workbook.xml` ohne Obergrenze. `WorktimeWorkbook.detects()` und `parse()` rufen für jeden Blattnamen `workbook.sheet(name)` auf; das baute jedes Mal ein neues `XLSXPackage` und entpackte/parste `workbook.xml`, Relationships, `sharedStrings.xml`, `styles.xml` und das Blatt neu (jeweils mit frischem 50-MB-Budget). Ein kleiner, präparierter Upload (viele `<sheet>`-Einträge, die auf dasselbe Blatt zeigen) erzeugte so O(N × Größe) Arbeit innerhalb der globalen `auth_lock`-Transaktion (`ImportService.upload`).

## Änderung

- `ImportLimits.maxSheets = 256`; mehr `<sheet>`-Elemente führen zu `ImportErrors.tooManySheets` (`too_many_sheets`, 400, deutsche Meldung in `ImportErrorMiddleware.messages`).
- `ImportWorkbook.Storage.xlsx` hält jetzt das `XLSXPackage` statt der Rohdaten. `XLSXPackage` (`@unchecked Sendable`, `NSLock`) cached Arbeitsmappe, Relationships, Shared Strings, Styles und geparste Blätter (nach aufgelöstem Pfad, sodass mehrere `<sheet>`-Einträge auf denselben Teil ihn nur einmal parsen). Das Entpackbudget (50 MB) wird je `sheet(named:)`-Aufruf zurückgesetzt, wie zuvor je frischem Paket.
- `parseCounts` je Paketteil dient nur Tests.
- Verhalten gültiger Arbeitsmappen unverändert.

## Tests

`XLSXSheetLimitTests` in `Tests/TimetrackKitTests/ImportEngineTests.swift`: 257 Blätter abgelehnt (inkl. Meldung vorhanden); 256 Blätter importierbar und `detects()` parst jeden Teil höchstens einmal (Zählerprüfung, zeitunabhängig); mehrere reguläre Blätter importieren weiter. Testergebnisse siehe Abschlussbericht der Session.

## Hinweise

- Der Test baut Arbeitsmappen mit vielen `<sheet>`-Einträgen auf einen Blatt-Teil, weil `maxZipEntries = 64` echte Mehrblatt-Archive ohnehin begrenzt.
- Neuer Fehlercode `too_many_sheets`: nicht in `contracts/openapi.yaml` aufgeführt (wie andere Importcodes nur im Changelog); keine Vertragsversion angehoben.
