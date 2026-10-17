## Was ändert dieser Pull Request?

<!-- Kurz, auf Deutsch. Verweis auf Issue, ADR oder Arbeitspaket. -->

## Prüfung

- [ ] `scripts/check-all.sh` (bzw. `--fast`) läuft durch; Tests mit `swift test --build-system native`
- [ ] Bei API-Änderung: `contracts/openapi.yaml` angepasst, Version erhöht, `scripts/contract-json.sh` ausgeführt
- [ ] Dokumentation mitgepflegt (`docs/STATUS.md`, betroffene Fachdokumente, ggf. ADR)

## Projektregeln

- [ ] Code, Kommentare, Tests und Bezeichner auf Englisch; Oberfläche und nutzerseitige Texte auf Deutsch
- [ ] Keine echten personenbezogenen Daten, keine Geheimnisse; Testdaten sind synthetisch
- [ ] Kontentrennung gilt auch für MCP, Exporte, Anhänge, Jobs, Suche und Push
- [ ] Vorschläge sind nicht als Nutzerentscheidungen dargestellt; offene Details sind kenntlich
