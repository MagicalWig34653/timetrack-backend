<script setup lang="ts">
import { withBase } from 'vitepress';

const shots = [
  { src: '/screenshots/ios-heute.png', alt: 'iPhone, Ansicht Heute mit laufendem Zeitabschnitt, Fortschrittsring und Zeitkonto', caption: 'Heute (iPhone)', phone: true },
  { src: '/screenshots/ios-zeit-dunkel.png', alt: 'iPhone, dunkles Design, Wochenübersicht mit Abschnitten für Arbeit, Fahrt und Schule', caption: 'Woche, dunkel (iPhone)', phone: true },
  { src: '/screenshots/ios-urlaub.png', alt: 'iPhone, Urlaubskonto mit Anspruch, genehmigten und geplanten Tagen', caption: 'Urlaub (iPhone)', phone: true },
  { src: '/screenshots/mac-heute.png', alt: 'Mac-App, Heute mit Start-Knopf, Fortschrittsring und Abschnittsliste', caption: 'Heute (Mac)', phone: false },
];
</script>

<template>
  <figure class="shots" aria-label="Screenshots der nativen Apps">
    <div v-for="s in shots" :key="s.src" :class="['shot', { phone: s.phone }]">
      <img :src="withBase(s.src)" :alt="s.alt" loading="lazy" />
      <figcaption>{{ s.caption }}</figcaption>
    </div>
  </figure>
  <p class="shots-note">Screenshots der nativen Apps (Entwicklungsstand) mit ausschließlich erfundenen Beispieldaten.</p>
</template>
