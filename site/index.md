---
layout: home
title: Selbst gehostete Zeiterfassung
hero:
  name: Timetrack
  text: Selbst gehostete Zeiterfassung
  tagline: Für Auszubildende und Beschäftigte. Zeiten erfassen, Urlaub und Planung im Blick, Berichtsheft vorbereiten. Auf deinem Server, mit deinen Daten.
  image:
    src: /logo.svg
    alt: Timetrack-Symbol
  actions:
    - theme: brand
      text: Dokumentation
      link: /docs/
    - theme: alt
      text: Einrichtung
      link: /docs/einrichtung
    - theme: alt
      text: GitHub
      link: https://github.com/MagicalWig34653/timetrack-backend
features:
  - icon: ⏱️
    title: Zeiterfassung
    details: Start und Stopp für Arbeit, Fahrt und Schule, nachträgliche Korrekturen, Tages- und Wochen-Soll, Zeitkonto. Rohzeit, Korrektur und gerundete Bewertung bleiben getrennt.
  - icon: 🗓️
    title: Planung und Urlaub
    details: Arbeitsmodelle mit Gültigkeitszeitraum, Feiertage, Urlaubs- und Abwesenheitskonto, Planungen, die du gezielt mit anderen teilen kannst. Standardmäßig ist alles privat.
  - icon: 📓
    title: Berichtsheft
    details: Felder für Lernfeld, Zeit und Notizen und eine kopierbare Ausgabe für das IHK-Portal. Entwürfe sind bearbeitbar; es werden keine Tätigkeiten erfunden.
  - icon: 📤
    title: Import und Export
    details: CSV, XLSX und PDF, dazu die Arbeitszeit-Tabelle. Importe mit Vorschau und Rücknahme, Export auch als Selbstauskunft deiner Daten.
  - icon: 📱
    title: PWA und native Apps
    details: Installierbare Web-App, dazu SwiftUI-Apps für iPhone, iPad, Mac und Apple Watch mit Widgets. Anmeldung mit Passkeys.
  - icon: 🤖
    title: MCP für ChatGPT und Claude
    details: Ein MCP-Endpunkt mit OAuth oder persönlichen Tokens. Dieselben Fachregeln und Kontorechte wie in der App, getrennt vom App-Login.
  - icon: 🔒
    title: Datenschutz von Grund auf
    details: Registrierung nur per Einladung, Kontentrennung auch bei MCP, Exporten, Anhängen und Push. Kein Tracking, keine Fremdanbieter-Pflicht.
  - icon: 🧩
    title: Flexibel zu betreiben
    details: MariaDB oder SQLite, Dateien in der Datenbank, in S3 oder auf einem lokalen Pfad. Ein Docker-Image für amd64 und arm64.
  - icon: 📜
    title: Freie Software
    details: AGPL-3.0-only. Der Quellcode, die Entscheidungen und der API-Vertrag liegen offen im Repository.
---

<div class="vp-doc home-content">

## So sieht es aus

<p class="lead">Die nativen Apps teilen Backend, Fachregeln und Gestaltung mit der PWA. Hier ein Ausschnitt mit Beispieldaten.</p>

<Screenshots />

## Aufbau

<p class="lead">Ein Swift-Backend ist die einzige Quelle der Fachregeln. Alle Clients, auch KI-Assistenten über MCP, sprechen mit denselben Diensten und unterliegen denselben Kontorechten.</p>

<Architecture />

Details stehen in der [Architektur](/docs/architektur) und in den [Architekturentscheidungen](/adr/).

## Loslegen

<div class="link-grid">
  <a href="./docs/einrichtung">Einrichtung<span>Lokal starten, Tests, Konfiguration</span></a>
  <a href="./docs/betrieb">Betrieb<span>Backup, Restore, Swarm, Reverse Proxy</span></a>
  <a href="./docs/mcp">MCP-Anbindung<span>ChatGPT, Claude und eigene Clients</span></a>
  <a href="./api/" target="_self">API-Referenz<span>OpenAPI-Vertrag, durchsuchbar</span></a>
  <a href="./docs/konzept">Konzept<span>Anforderungen und offene Details</span></a>
  <a href="https://github.com/MagicalWig34653/timetrack-backend">GitHub<span>Quellcode, Issues, Releases</span></a>
</div>

## Stand und Ehrlichkeit

Timetrack ist ein privates Open-Source-Projekt in aktiver Entwicklung. Backend und PWA sind umgesetzt; was tatsächlich geprüft ist und was offen bleibt (zum Beispiel echte ChatGPT- und Claude-Connectoren, Passkeys auf Geräten, Betrieb im Swarm), steht jeweils im Dokument [Umsetzung](/docs/umsetzung) und im Repository unter `docs/STATUS.md`. Vorschläge in der Dokumentation sind keine Nutzerentscheidungen und als solche gekennzeichnet.

## Lizenz

Timetrack steht unter der [GNU Affero General Public License v3.0](https://www.gnu.org/licenses/agpl-3.0.html) (AGPL-3.0-only). Wer eine geänderte Version als Dienst betreibt, muss den Quellcode dieser Version den Nutzern des Dienstes anbieten. Abhängigkeiten und ihre Lizenzen: [Lizenzinventar](/docs/lizenzen).

</div>
