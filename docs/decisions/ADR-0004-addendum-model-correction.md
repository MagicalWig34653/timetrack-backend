# ADR-0004 Nachtrag: Korrektur eines Arbeitsmodells mit Vorschau

Stand: 17.10.2026 (Paket M1). Nutzerwunsch: Werte einer Modellversion nachträglich prüfen und ändern können, auch wenn sich dadurch Zeiten ändern.

**Grundsatz.** Korrektur mit Vorschau; Vergangenheit ändert sich bewusst nur auf ausdrücklichen Nutzerwunsch. Der sichere Weg bleibt `POST /work-models` (neue Version ab Datum, Vorversion endet am Vortag).

**Korrekturpfad.** `PUT /work-models/{id}` ersetzt alle bearbeitbaren Felder einer Version, optional auch `validFrom`/`validTo`. Segmente speichern nur Roh- und effektive Zeiten, Bewertungen werden beim Lesen berechnet: Die Korrektur ändert daher die Bewertung aller Tage der Version, nicht die erfassten Zeiten.

- Prüfung wie bei POST. `validFrom` muss nach dem `validFrom` der Vorversion liegen, `validTo` vor dem Beginn der Folgeversion, sonst 409 `model_overlap`. Schließt die Vorversion unmittelbar an (oder offen), wird ihr `validTo` auf den Vortag des neuen `validFrom` gesetzt.
- Optimistische Nebenläufigkeit: `WorkModel.version` (Zähler, fehlend = 1, nur im JSON-Payload, keine Migration). Optionaler Header `If-Match`; Abweichung 412 `stale_version`.
- `POST /work-models/{id}/preview` (gleicher Body, nichts wird gespeichert) liefert `affectedFrom/To`, `affectedDays`, Zeitkonto bis heute vorher/nachher, Differenz, geänderte Felder und ggf. das neue Ende der Vorversion. Es nutzt die vorbereitete Auswertung aus X1 (einmal laden, zweimal rechnen; 10 Statements, getestet).
- Audit: Zeile `work_model.updated` in `account_audit` (nur IDs).
- Kontentrennung: fremde IDs liefern 404. MCP bleibt unverändert.

**Folgen.** Die PWA zeigt vor dem Speichern eine deutliche Warnung, die Vorschau und verlangt eine Bestätigung. Ältere Server ohne `version` bieten nur „Ab einem Datum ändern“ an.
