# ADR-0028: Rechtsprofil für Jugendliche (R2)

Status: umgesetzt im R2-Worktree; fachliche Prüfung durch eine qualifizierte Person offen.

## Entscheidung

Ein Arbeitsmodell trägt `legalProfileId`. Es ist eine datierte Modellversion; ein Profilwechsel erfolgt über ein neues Modell mit `validFrom`. Für vorhandene Modelle gilt unverändert `arbzg-adult-de`. Das neue Profil `jarbschg-minor-de` ist für Jugendliche unter 18 auswählbar; Auszubildende ab 18 wählen das Erwachsenenprofil. Die API legt kein Geburtsdatum ab und leitet den Wechsel nicht automatisch ab.

`GET /api/v1/legal-profiles` liefert Regeln, deutsche Bezeichnungen und Quellen. Beide Profile sind Datenwerte im Backend. `breakHints` und `legalWarnings` sind Hinweise anhand erfasster tatsächlicher Zeiten; es werden keine Pausen erfunden, Zeiten nicht abgewiesen und Sonderfälle nicht automatisch genehmigt. Die Texte sind **informativ und keine Rechtsberatung**.

Für Jugendliche: 8 Stunden täglich, 40 Stunden je Montag–Sonntag-Woche, höchstens fünf Beschäftigungstage, 30 Minuten Pause bei mehr als 4,5 bis 6 Stunden, 60 Minuten bei mehr als 6 Stunden, Pausenteile mindestens 15 Minuten und höchstens 4,5 Stunden ohne Pause, 12 Stunden tägliche Freizeit. Samstag/Sonntag lösen Hinweise aus; die gesetzlichen Ausnahmen werden nicht durch pauschale Freigaben im Modell simuliert. Die Ausgleichsmöglichkeiten des § 8 Abs. 2/2a, Sonderbereiche und Zuschläge bleiben fachlich zu prüfen. Quellen: [§ 8 JArbSchG](https://www.gesetze-im-internet.de/jarbschg/__8.html), [§ 11](https://www.gesetze-im-internet.de/jarbschg/__11.html), [§ 13](https://www.gesetze-im-internet.de/jarbschg/__13.html), [§ 15](https://www.gesetze-im-internet.de/jarbschg/__15.html), [§ 16](https://www.gesetze-im-internet.de/jarbschg/__16.html), [§ 17](https://www.gesetze-im-internet.de/jarbschg/__17.html).

Für die Berufsschule wird `schoolLessonCount` pro Tag ausdrücklich erfasst (Unterrichtsstunden von mindestens 45 Minuten). Die Zeit eines Schulsegments allein enthält auch Pausen und verrät die Unterrichtsstundenzahl nicht. Ab sechs Stunden an einem Tag ersetzt einmal je Woche eine Gutschrift von acht Stunden die Tagesabschnitte; weitere Arbeit am angerechneten Tag wird als Hinweis angezeigt. Bei Blockunterricht mit insgesamt mindestens 25 Stunden an mindestens fünf Tagen derselben Woche werden fünf Schultage mit je acht Stunden bewertet. Arbeit vor 9 Uhr an einem Schultag löst einen Hinweis aus. Quelle: [§ 9 JArbSchG](https://www.gesetze-im-internet.de/jarbschg/__9.html). Notwendige Wegezeiten zwischen Schule und Ausbildungsstätte und die Einordnung von Blockunterricht benötigen weitere fachliche Prüfung; bis dahin darf die UI keine Rechtskonformität behaupten.

**Produktannahme:** Die festen Gutschriften 8/40 Stunden entsprechen dem R2-Auftrag. § 9 Abs. 2 spricht von der *durchschnittlichen* täglichen bzw. wöchentlichen Arbeitszeit. Bei einem Arbeitsmodell unter 40 Stunden können die gesetzlichen Anrechnungswerte daher anders sein. Diese Abweichung muss fachlich entschieden werden, bevor die Oberfläche die Gutschrift als gesetzlichen Wert bezeichnet.

Erwachsene behalten ihre bisherige betriebliche Schulschwelle und die bisherigen Pausenhinweise nach [§ 4 ArbZG](https://www.gesetze-im-internet.de/arbzg/__4.html). Rohzeit, Rundung, betriebliche Sollzeit und gesetzliche Hinweise bleiben getrennt. Wochen- und Ruhezeitwarnungen verwenden die effektiven, ungerundeten Abschnitte. Schulzeitgutschriften fließen in die Wochenbewertung, auch wenn das Segment kürzer als acht Stunden ist.

## Technischer Vertrag

Migration `r2.add_legal_work_profile` ergänzt optionale Spalten `work_models.legal_profile_id` und `day_preferences.school_lesson_count`. `NULL` bei alten Modellen bedeutet `arbzg-adult-de`; alte Tagespräferenzen erhalten keine Unterrichtsstundenzahl. Die API weist unbekannte Profil-IDs ab. `DayEvaluation` und die Tage von `TimeWeek` nennen Profil und Hinweise, Statistikbuckets zählen Tage mit Hinweisen. REST, MCP, Export und Konto lesen denselben Bewertungsweg.

Die Quellen wurden am 24.10.2026 geprüft. Rechtstexte und Ausnahmen können sich ändern; vor produktiver Nutzung ist eine fachliche Prüfung nötig.
