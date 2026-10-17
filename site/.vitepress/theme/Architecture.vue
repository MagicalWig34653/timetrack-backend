<template>
  <div class="arch" role="img" aria-label="Architektur: Clients sprechen über REST und MCP mit dem Swift-Backend, das MariaDB oder SQLite und Dateispeicher nutzt">
    <div class="arch-col">
      <h4>Clients</h4>
      <div class="box">PWA<span>Svelte, installierbar</span></div>
      <div class="box">Apple-Apps<span>iOS, iPadOS, macOS, watchOS</span></div>
      <div class="box">KI-Clients<span>ChatGPT, Claude, andere</span></div>
      <div class="box">Kurzbefehle<span>Automation per Geräte-Token</span></div>
    </div>
    <div class="arch-arrow" aria-hidden="true">REST<br />MCP<br />→</div>
    <div class="arch-col core">
      <h4>Backend</h4>
      <div class="box accent">Swift, Vapor, Fluent<span>Konten und Passkeys, Zeit-Engine, Planung, Berichtsheft, Export/Import, OAuth, MCP</span></div>
      <div class="box">Eine Fachlogik<span>REST und MCP nutzen dieselben Regeln und Kontorechte</span></div>
    </div>
    <div class="arch-arrow" aria-hidden="true">→</div>
    <div class="arch-col">
      <h4>Speicher</h4>
      <div class="box">MariaDB 12.3<span>empfohlen</span></div>
      <div class="box">SQLite<span>Einzelinstanz</span></div>
      <div class="box">Dateien<span>Datenbank, S3 oder lokaler Pfad</span></div>
    </div>
  </div>
</template>
