import fs from 'node:fs';
import path from 'node:path';
import { defineConfig } from 'vitepress';

// Base path: GitHub project pages are served below /<repository>/. Override with SITE_BASE for other hosting.
const base = process.env.SITE_BASE ?? '/timetrack-backend/';
const repo = process.env.SITE_REPO ?? 'MagicalWig34653/timetrack-backend';
const has = (route: string) => fs.existsSync(path.resolve(__dirname, '../docs-src', `${route}.md`));
const item = (text: string, route: string) => (has(route) ? [{ text, link: `/${route}` }] : []);

const adrs = fs.existsSync(path.resolve(__dirname, '../docs-src/adr'))
  ? fs
      .readdirSync(path.resolve(__dirname, '../docs-src/adr'))
      .filter((f) => f.startsWith('adr-'))
      .sort()
      .map((f) => {
        const title = fs.readFileSync(path.resolve(__dirname, '../docs-src/adr', f), 'utf8').match(/^# (.*)$/m)?.[1] ?? f;
        return { text: title.replace(/^ADR-?(\d+[a-z]?)[:\s–-]*/i, '$1 · '), link: `/adr/${f.replace(/\.md$/, '')}` };
      })
  : [];

export default defineConfig({
  lang: 'de-DE',
  title: 'Timetrack',
  titleTemplate: ':title · Timetrack',
  description: 'Selbst gehostete Zeiterfassung für Auszubildende und Beschäftigte: Zeiten, Planung, Urlaub, Berichtsheft, Import/Export, PWA, native Apps und MCP.',
  base,
  srcDir: '.',
  srcExclude: ['README.md', 'node_modules/**'],
  // Generated copies live in docs-src/ (see scripts/sync-docs.mjs); the URL drops the directory name.
  rewrites: { 'docs-src/:rest*': ':rest*' },
  cleanUrls: true,
  lastUpdated: false,
  ignoreDeadLinks: [/^\/api\//],
  head: [
    ['link', { rel: 'icon', type: 'image/svg+xml', href: `${base}logo.svg` }],
    ['meta', { name: 'theme-color', content: '#2563EB' }],
  ],
  themeConfig: {
    logo: '/logo.svg',
    siteTitle: 'Timetrack',
    nav: [
      { text: 'Installieren', link: '/docs/installation', activeMatch: '^/docs/(installation|update|image-bauen)' },
      { text: 'Dokumentation', link: '/docs/', activeMatch: '^/docs/(?!installation|update|image-bauen)' },
      { text: 'API', link: '/api/', target: '_self' },
      { text: 'Entscheidungen', link: '/adr/', activeMatch: '^/adr/' },
    ],
    sidebar: {
      '/docs/': [
        {
          text: 'Installation',
          items: [
            ...item('Überblick und Auswahl', 'docs/installation'),
            ...item('Docker Compose (ein Server)', 'docs/installation/compose'),
            ...item('Docker Swarm (Cluster)', 'docs/installation/swarm'),
            ...item('Eigene MariaDB', 'docs/installation/mariadb'),
            ...item('Reverse Proxy und TLS', 'docs/installation/proxy'),
            ...item('Ersteinrichtung', 'docs/installation/ersteinrichtung'),
            ...item('Aktualisieren', 'docs/update'),
            ...item('Sichern und Wiederherstellen', 'docs/installation/backup'),
            ...item('Probleme und Lösungen', 'docs/installation/probleme'),
            ...item('Konfiguration', 'docs/installation/konfiguration'),
          ],
        },
        { text: 'Image selbst bauen', items: [...item('Image bauen', 'docs/image-bauen')] },
        {
          text: 'Nutzung',
          items: [
            ...item('MCP (ChatGPT, Claude)', 'docs/mcp'),
            ...item('Kurzbefehle', 'docs/shortcuts'),
            ...item('Import: Arbeitszeit-Tabelle', 'adr/adr-0013-arbeitszeit-tabelle'),
            ...item('Import und Export: Regeln', 'adr/adr-0006-etappe3b-export-import-dateispeicher'),
            { text: 'API-Referenz', link: '/api/', target: '_self' },
          ],
        },
        {
          text: 'Hintergrund',
          collapsed: true,
          items: [
            { text: 'Startseite der Dokumentation', link: '/docs/' },
            ...item('Konzept', 'docs/konzept'),
            ...item('Architektur', 'docs/architektur'),
            ...item('Umsetzung in Etappen', 'docs/umsetzung'),
            ...item('Betrieb und Backup', 'docs/betrieb'),
            ...item('Deployment-Referenz (Swarm)', 'docs/deployment'),
            ...item('Entwicklung einrichten', 'docs/einrichtung'),
            ...item('CI und Pages', 'docs/ci'),
            ...item('Designsprache', 'docs/design'),
            ...item('Entwicklungsablauf', 'docs/entwicklungsablauf'),
            ...item('Lizenzen', 'docs/lizenzen'),
            { text: 'Entscheidungen (ADR)', link: '/adr/' },
          ],
        },
      ],
      '/adr/': [{ text: 'Architekturentscheidungen', items: [{ text: 'Übersicht', link: '/adr/' }, ...adrs] }],
    },
    socialLinks: [{ icon: 'github', link: `https://github.com/${repo}` }],
    outline: { level: [2, 3], label: 'Auf dieser Seite' },
    docFooter: { prev: 'Zurück', next: 'Weiter' },
    darkModeSwitchLabel: 'Design',
    sidebarMenuLabel: 'Menü',
    returnToTopLabel: 'Nach oben',
    langMenuLabel: 'Sprache',
    lightModeSwitchTitle: 'Zum hellen Design wechseln',
    darkModeSwitchTitle: 'Zum dunklen Design wechseln',
    search: {
      provider: 'local',
      options: {
        translations: {
          button: { buttonText: 'Suchen', buttonAriaLabel: 'Suchen' },
          modal: { noResultsText: 'Keine Treffer für', resetButtonTitle: 'Zurücksetzen', footer: { selectText: 'auswählen', navigateText: 'navigieren', closeText: 'schließen' } },
        },
      },
    },
    footer: {
      message: 'Freie Software unter der GNU Affero General Public License v3.0 (AGPL-3.0-only). Alle Beispieldaten auf dieser Seite sind synthetisch.',
      copyright: 'Timetrack',
    },
  },
});
