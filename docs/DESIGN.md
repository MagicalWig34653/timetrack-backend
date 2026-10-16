# Designsprache Timetrack

Stand: 15.10.2026. Kanonisch für **alle** Oberflächen (PWA jetzt, native Apps später sinngemäß; dort gelten zusätzlich Apple HIG und Liquid Glass). Entscheidung: `decisions/ADR-0014-designsprache.md`. Native Umsetzung (Swift-Paket TimetrackDesign, Akzent-System, Icons): Apple-Repo `docs/DESIGN-NATIVE.md` und `docs/ICONS.md`; Akzent dort je Gerät wählbar, getrennt vom App-Symbol. Umsetzungsstand: `STATUS.md`.

## Herkunft und Einordnung

Vorbild ist ein vom Nutzer bereitgestellter UI-Entwurf eines anderen eigenen Projekts (Svelte 5, Tailwind 4, shadcn-svelte „nova“, bits-ui; Lizenz dort AGPL-3.0-only wie hier). Übernommen wird die **Gestaltung** (Tokens, Raster, Muster, Glasflächen, Akzentlogik), nicht dessen Fachinhalt, Marke, Texte oder Bildmaterial. Die Werte unten wurden aus dem Entwurf gelesen und hier eigenständig beschrieben; Abweichungen stehen unter „Anpassungen für Timetrack“. Der Entwurf selbst liegt nicht im Repository.

## Grundsätze

1. **Ruhig und aufgeräumt**: neutrale Flächen, viel Weißraum, wenige Farben; Akzentfarbe nur für Hauptaktion, aktive Navigation, Schalter und Fokus. Kein großflächiges Farbbranding.
2. **Eine Sache pro Abschnitt**: zusammengehörige Einstellungen in benannten Abschnitten/Karten, überwiegend einspaltig, Formularkarten ≤ 820 px.
3. **Glas nur für Rahmen, nie für Inhalt**: Seitenleiste, Kopfzeile, Dialoge, Popover und Tooltips sind leicht transparent mit Unschärfe; Karten mit Daten und alle Schrift bleiben deckend. Immer mit Rückfall (siehe Glas).
4. **Lesbar und bedienbar**: Kontrast ≥ 4,5:1 für Text, Standardsteuerung 40 px hoch (kleine Aktionen 32 px), sichtbarer Fokus, keine Information nur über Farbe, Bewegung reduzierbar.
5. **Gleiches Muster überall**: Seitenkopf, Karten, Listen, Dialoge, leere Zustände, Fehler sehen auf jeder Seite gleich aus.

## Tokens

Neutrale **Zinc**-Palette in OKLCH (Tönung Hue ≈ 286, sehr geringe Chroma), Tailwind-4-Theme `@theme inline` mit shadcn-Variablen.

| Token | Hell | Dunkel |
| --- | --- | --- |
| `--background` / Karte / Popover | `oklch(1 0 0)` | `oklch(0.141 0.005 285.823)` |
| `--foreground` | `oklch(0.141 0.005 285.823)` | `oklch(0.985 0 0)` |
| `--primary` (neutral, nur Fallback ohne Akzent) | `oklch(0.21 0.006 285.885)` | `oklch(0.92 0.004 286.32)` |
| `--secondary` / `--muted` / `--accent` (Flächen) | `oklch(0.967 0.001 286.375)` | `oklch(0.274 0.006 286.033)` |
| `--muted-foreground` | `oklch(0.552 0.016 285.938)` | `oklch(0.705 0.015 286.067)` |
| `--border` | `oklch(0.92 0.004 286.32)` | `oklch(1 0 0 / 10%)` |
| `--input` | `oklch(0.92 0.004 286.32)` | `oklch(1 0 0 / 15%)` |
| `--ring` | `oklch(0.705 0.015 286.067)` | `oklch(0.552 0.016 285.938)` |
| `--destructive` | `oklch(0.577 0.245 27.325)` | `oklch(0.704 0.191 22.216)` |
| `--sidebar` | `#fafafa` | `#18181b` |
| `--chart-1` / `--chart-2` | `#2563eb` / `#f59e0b` | `#60a5fa` / `#f59e0b` |

Radius `--radius: 0.625rem` (Karten 10 px, Steuerelemente 6–8 px, Dialoge 12–16 px, Chips voll rund). Schatten sehr dezent: Karten `0 1px 2px #00000003`, Popover/Tooltip `0 8–12px 30–40px #0002`. Übergänge 150 ms (Hintergrund/Rand/Transform), bei `prefers-reduced-motion` keine.

### Typografie

System-Schrift (`ui-sans-serif, system-ui, -apple-system, 'Segoe UI'`; keine CDN-Fonts, optional gebündelte Inter), Fließtext 15 px/1.6.
Seitentitel 32 px (mobil 28), Gewicht 650, Laufweite −0,8 px · Abschnittstitel 21 px/600 · Kartentitel 17 px/600 · Beschriftung 14 px/500 · Hilfe/Meta 13 px, kleine Meta 10–12 px · Kennzahlen 34 px/600 (−0,7 px).
Zahlen mit tabellarischen Ziffern (`font-variant-numeric: tabular-nums`) für Zeiten und Summen. Dauern immer `h:mm`.

### Akzentfarbe

Je Person wählbar (Vorgaben + freie Farbwahl) und **im Konto gespeichert** (ADR-0020, `GET/PATCH /me/preferences`), damit PWA und Apple-Apps sie teilen; lokal nur als Sofort-Cache. Transparenz und App-Symbol bleiben Gerätewahl. Aus der gewählten Farbe werden vier Tokens berechnet: `--ui-accent` (Primärfläche), `--ui-accent-foreground` (Weiß oder Schwarz je Kontrast), `--ui-accent-ink` (Akzent als **Schriftfarbe**, bei Bedarf in 10-%-Schritten abgedunkelt/aufgehellt bis ≥ 4,5:1 gegen den Hintergrund), `--ui-accent-soft` (Mischung 9 % hell / 18 % dunkel mit `--background`, für aktive Navigation, Chips, Hervorhebung). **Standard-Akzent Timetrack: ruhiges Blau `#2563EB`.** Ungültige Eingaben werden verworfen. Statusfarben (Fehler/Warnung/OK) sind unabhängig vom Akzent.

## Layout

- **Shell**: feste Seitenleiste 256 px links (`--sidebar`, 1 px Rand, Glas), Kopfzeile 60 px (Brotkrumen links; rechts Hinweise, Konto/Person, Darstellung Hell/Dunkel/System, Akzent), Inhalt `max-width: 1240 px`, Innenabstand 36/40 px (≤ 1100 px: 24; ≤ 760 px: 22/16). Unter 760 px wird die Seitenleiste zum ausfahrbaren Menü (Glas-Panel mit Overlay).
- **Seitenleiste**: Marke oben (Symbol 34 px im 1-px-Rahmen + Name), Einstellungssuche, Gruppen mit kleinen Gruppentiteln, ≤ 7 Hauptbereiche, Konto/Sicherheit, Hilfe und Statuszeile unten. Aktiver Eintrag: `--ui-accent-soft` Hintergrund + `--ui-accent-ink` Text, Zähler als kleine Chips.
- **Seitenkopf** (`pagehead`): links Titel + eine erklärende Zeile (muted), rechts Hauptaktion (Akzent) und höchstens eine Nebenaktion (Outline); mobil gestapelt. Abstand darunter 32 px (mobil 28).
- **Karten** (`panel`): 1 px Rand, Radius 10, Innenabstand 28 (≤ 1100: 22, mobil 17), Titelzeile + optionaler Hilfe-Button, Inhalt, optionale Fußzeile mit Aktion; **Kennzahlenkarten** als Raster (4/2/1 Spalten): Titel + Symbol, große Zahl, Erläuterung.
- **Listen/Tabellen**: Zeilen mit dünnen Trennern statt Zebra; Mobil als Kartenliste; Filterzeile über der Liste (Suche 40 px, Selects, Ergebniszähler); Umschalter „Karten | Tabelle“ als Tabs.
- **Formulare**: Beschriftung 14 px über dem Feld, Feld 40 px (min.), Fehlertext darunter in `--destructive`, Hilfe-Icon (Popover) für Begriffe, Schalter statt Checkbox für Ein/Aus, Speichern-Button rechts unten in der Karte; ungespeicherte Änderungen markiert.
- **Dialoge**: Overlay `black/10` + leichte Unschärfe, Inhalt als Glas-Fläche, Kopf (Titel + Beschreibung), scrollender Inhalt, Fuß mit Aktionen; Schließen-Kreuz und Escape; Fokusfalle; große Auswahldialoge (Galerie) mit Seitenliste, Suche und Vorschaukarten.
- **Rückmeldung**: Toast unten rechts (Rand, Schatten, Radius 8, schließbar, `aria-live`), Banner unter der Kopfzeile für Zustände (Offline, Modul aus, Demo), Inline-Alerts in Karten.
- **Status**: Chips (Radius voll, 20 px hoch, Text + optional Punkt) mit Text immer dabei; Farben nur Zusatz.

## Glas

| Fläche | Hintergrund | Unschärfe |
| --- | --- | --- |
| Seitenleiste | `color-mix(in srgb, var(--sidebar) 88%, transparent)` | `blur(22px) saturate(1.15)` |
| Kopfzeile | `color-mix(in srgb, var(--background) 85%, transparent)` | `blur(18px)` |
| Dialog, Popover/Hilfe | `color-mix(in srgb, var(--popover) 90%, transparent)` | `blur(22px) saturate(1.15)` |
| Auswahlgalerie (großer Dialog) | `… 86% …` | `blur(30px) saturate(1.25)` |
| Diagramm-Tooltip | `color-mix(in srgb, var(--background) 80%, transparent)`, Rand 75 % | `blur(14px) saturate(1.2)` |
| Overlay hinter Dialogen | `black/10` | `backdrop-blur-xs` nur mit `supports-backdrop-filter` |

Regeln: Text/Symbole stets deckend; **Rückfall deckend** bei `@media (prefers-reduced-transparency: reduce)` und `@supports not (backdrop-filter: blur(1px))`; Kontrast immer gegen den ungünstigsten Hintergrund prüfen (Dunkelmodus!); Karten mit Daten und Diagramme nie transparent; höchstens eine große Unschärfefläche gleichzeitig animiert (Leistung auf Mobilgeräten).

## Muster für Timetrack

| Bereich | Muster |
| --- | --- |
| Heute | Kennzahlenkarten (Soll/Ist/Saldo/Zeitkonto), Timer-Karte, Tageszeitleiste als ruhiges Diagramm, „Heute relevant“-Liste |
| Zeit, Tag | Wochenliste als Karten, Tagesdetail mit Zeitleiste, Korrekturdialoge |
| Kalender/Urlaub | Monatsraster mit Chips, Seitenpanel/Dialog für Tag; Urlaubskonto als Kennzahlenkarten |
| Berichtsheft | Wochenkarte je Tag, Summenzeile, „Als Text kopieren“ als Hauptaktion |
| Import/Export | Assistent als Schrittleiste im Dialog/Seite, Vorschau als Tabelle mit Statuschips |
| Einstellungen | Abschnittskarten, links Unterpunkte (Tabs), Einstellungssuche |
| Auswahl/Galerie | Dialog mit Kategorieliste + Vorschaukarten (z. B. Kachel hinzufügen, später Dashboard-Layout) |

Informationsarchitektur (Seitenleiste, Module blenden Einträge aus — ADR-0012): **Alltag** (Heute, Zeit, Kalender, Berichtsheft) · **Planung** (Urlaub, Abwesenheiten, Geteilt, Vorschläge) · **Daten** (Export, Import) · **Verwaltung** nur Admin (Einladungen, Module; der Dateispeicher liegt nur in den Einstellungs-Tabs) · unten Hinweise, Einstellungen/Konto & Sicherheit, Hilfe.

## Anpassungen für Timetrack (gegenüber dem Vorbild)

- Standard-Akzent Blau statt Teal; Zeitarbeit braucht keine Wärme-/Heizfarben, Diagrammfarben aus `--chart-*` + Statusfarben für Soll/Ist/Pause.
- Deutsche Texte in `i18n`-Ressourcen; kein Demo-Banner, keine „Person wechseln“-Auswahl.
- Echte Rechte, Module und Offline-Zustand statt Demo-Simulation; Offline-Banner nach `docs/decisions/ADR-0010`.
- Dashboard-Anordnung per Drag-and-drop, Gerätekarte und Wochenplan-Editor des Vorbilds werden **nicht** übernommen (fachfremd).

## Barrierefreiheit (Pflicht)

Fokus sichtbar (2 px Ring `--ring`, Offset), Tastaturbedienung für alles Interaktive, Touch-Ziele ≥ 40 px (Hilfe-Icons mindestens 32 px mit großer Trefferfläche), `aria-live` für Toasts, `aria-busy` bei Aktionen, Kontrast ≥ 4,5:1 (Text) / 3:1 (UI-Elemente) in Hell und Dunkel **und** auf Glasflächen, `prefers-reduced-motion`, `prefers-reduced-transparency`, `prefers-color-scheme` (Standard „System“), Zoom bis 200 % ohne horizontales Scrollen, mobil ab 390 px.

## Prüfung

Jede Umsetzung belegt Hell/Dunkel, 390 px und Desktop per Screenshot, Kontrastprüfung der Akzentableitung (Tests mit Beispielfarben), Rückfall ohne Transparenz (Emulation `prefers-reduced-transparency`), keine horizontale Scrollbar, Tastaturdurchlauf der Shell.


**Bekannte Abweichung Apps ↔ PWA (A8, 16.10.2026):** Verbindlich sind nur die Preset-IDs (`blue, teal, violet, green, orange, pink, graphite, custom`, ADR-0020). Die nativen Farbwerte weichen bei drei Presets von der PWA ab: Türkis #0EA5A4 (PWA #0D9488), Orange #F97316 (PWA #D97706), Rosa #EC4899 (PWA #DB2777); Blau, Violett, Grün, Graphit sind gleich.
