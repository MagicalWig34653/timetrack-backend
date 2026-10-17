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
      { text: 'Installieren', link: '/docs/installation' },
      { text: 'Dokumentation', link: '/docs/', activeMatch: '^/docs/(?!installation)' },
      { text: 'API', link: '/api/', target: '_self' },
      { text: 'Entscheidungen', link: '/adr/', activeMatch: '^/adr/' },
    ],
    sidebar: {
      '/docs/': [
        { text: 'Installieren', items: [...item('In 10 Minuten zum Laufen', 'docs/installation'), ...item('Aktualisieren und Migrationen', 'docs/update'), ...item('Ausführliche Deployment-Anleitung', 'docs/deployment')] },
        { text: 'Überblick', items: [{ text: 'Startseite der Dokumentation', link: '/docs/' }, ...item('Konzept', 'docs/konzept'), ...item('Architektur', 'docs/architektur'), ...item('Umsetzung in Etappen', 'docs/umsetzung')] },
        { text: 'Betrieb', items: [...item('Einrichtung', 'docs/einrichtung'), ...item('Betrieb und Backup', 'docs/betrieb'), ...item('CI und Pages', 'docs/ci')] },
        { text: 'Nutzung und Anbindung', items: [...item('MCP (ChatGPT, Claude)', 'docs/mcp'), ...item('Kurzbefehle', 'docs/shortcuts'), { text: 'API-Referenz', link: '/api/', target: '_self' }] },
        { text: 'Projekt', items: [...item('Designsprache', 'docs/design'), ...item('Entwicklungsablauf', 'docs/entwicklungsablauf'), ...item('Lizenzen', 'docs/lizenzen')] },
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
