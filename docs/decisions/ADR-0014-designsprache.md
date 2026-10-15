# ADR-0014: Designsprache (Zinc, Glasflächen, Akzentsystem)

Status: akzeptiert. Nutzerentscheidung 15.10.2026: Die Gestaltung eines vom Nutzer bereitgestellten UI-Entwurfs eines anderen Projekts gefällt (aufgeräumt, Backdrop/Glas) und soll festgehalten und für Timetrack übernommen werden.

## Entscheidung

- Kanonische Beschreibung in `docs/DESIGN.md` (Tokens, Typografie, Layout, Glas inkl. Rückfälle, Akzentsystem, Muster, Barrierefreiheit). Änderungen an der Designsprache nur dort und mit Verweis auf diesen ADR.
- Umsetzung in der PWA über das bestehende shadcn-svelte/Tailwind-4-Fundament: Zinc-Tönung der Tokens, Seitenleiste + Kopfzeile als Shell, Seitenkopf-/Karten-/Kennzahlenmuster, Glas für Rahmenflächen, wählbare Akzentfarbe (Standard Blau `#2563EB`), Standardsteuerung 40 px.
- Nur die **Gestaltung** wird übernommen (gleicher Eigentümer, AGPL-3.0-only); Fachinhalte, Marke und Texte des Vorbilds nicht. Native Apps interpretieren die Sprache mit Apple HIG/Liquid Glass (Farben, Abstände, Hierarchie, Akzent).

## Alternativen

Bestehende neutrale shadcn-Oberfläche behalten: verworfen (Nutzerwunsch, geringere Orientierung bei 15+ Seiten). Komplett eigenes Designsystem: verworfen (Aufwand, shadcn-Basis passt). Glas flächig: verworfen (Lesbarkeit, Leistung, Barrierefreiheit).

## Folgen

Alle PWA-Seiten ändern ihr Layout (Shell, Seitenkopf); Playwright-Tests nutzen Rollen/Texte und müssen angepasst werden dürfen, aber nicht ihre Aussage verlieren. Kontrast- und Rückfalltests sind Teil der Abnahme. Glas darf Inhalte nicht überdecken oder Lesbarkeit mindern; im Zweifel deckend.
