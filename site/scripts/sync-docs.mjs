// Copies the repository's German documentation into site/docs-src/ at build time (the copy is gitignored, the
// documents stay single-source in the repository). Rewrites relative links, escapes Vue syntax outside code,
// replaces internal infrastructure identifiers and fails if one of them survives.
//
// Environment:
//   SITE_REPO        GitHub "owner/name" used for source links (default MagicalWig34653/timetrack-backend)
//   SITE_REPO_BRANCH branch used for source links (default main)
//   PWA_DOCS_DIR     optional: path to the PWA repository's docs/ directory (adds docs/SHORTCUTS.md as a page)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const siteDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const root = path.resolve(siteDir, '..');
const out = path.join(siteDir, 'docs-src');
const repo = process.env.SITE_REPO || 'MagicalWig34653/timetrack-backend';
const branch = process.env.SITE_REPO_BRANCH || 'main';
const gh = `https://github.com/${repo}`;

/** Pages: repo path -> site route. Optional pages are skipped when the source file does not exist. */
const pages = [
  ['docs/KONZEPT.md', '/docs/konzept'],
  ['docs/ARCHITEKTUR.md', '/docs/architektur'],
  ['docs/UMSETZUNG.md', '/docs/umsetzung'],
  ['docs/DESIGN.md', '/docs/design'],
  ['docs/MCP.md', '/docs/mcp'],
  ['EINRICHTUNG.md', '/docs/einrichtung'],
  ['docs/BETRIEB.md', '/docs/betrieb'],
  ['docs/DEPLOYMENT.md', '/docs/deployment'], // written by another package; optional
  ['docs/CI.md', '/docs/ci'],
  ['docs/ENTWICKLUNGSABLAUF.md', '/docs/entwicklungsablauf'],
  ['docs/LIZENZEN.md', '/docs/lizenzen'],
];
const adrDir = path.join(root, 'docs/decisions');
for (const f of fs.existsSync(adrDir) ? fs.readdirSync(adrDir).sort() : []) {
  if (f.endsWith('.md')) pages.push([`docs/decisions/${f}`, `/adr/${f.replace(/\.md$/, '').toLowerCase()}`]);
}
if (process.env.PWA_DOCS_DIR) pages.push([path.join(process.env.PWA_DOCS_DIR, 'SHORTCUTS.md'), '/docs/shortcuts']);

const routeOf = new Map(pages.map(([src, route]) => [path.normalize(src), route]));
routeOf.set(path.normalize('docs/README.md'), '/adr/');

// Internal or personal identifiers that must not appear on the public site.
const redactions = [
  [/test\.example\.org/g, 'timetrack-test.example.org'],
  [/timetrack\.example\.org/g, 'timetrack.example.org'],
  [/com\.example/g, 'org.example'],
  [/ABCDE12345/g, 'TEAMID1234'],
  [/\/home\/user\/timetrack-backend/g, '/pfad/zu/timetrack-backend'],
  [/192\.168\.(\d+)\.(\d+)/g, '192.0.2.$2'],
];
const forbidden = /owner-name|owner-domain|192\.168|ABCDE12345|\/Users\/|@icloud|Az-Laske/i;

function escapeOutsideCode(markdown) {
  let inFence = false;
  return markdown
    .split('\n')
    .map((line) => {
      if (/^\s*(```|~~~)/.test(line)) { inFence = !inFence; return line; }
      if (inFence) return line;
      // keep inline code spans untouched, escape Vue interpolation and bare placeholders like <token> elsewhere
      return line
        .split(/(`[^`]*`)/)
        .map((part, i) => {
          if (i % 2 === 1) return part.includes('{{') ? `<span v-pre>${part}</span>` : part;
          return part
            .replace(/\{\{/g, '&#123;&#123;')
            .replace(/<(?!\/?(?:br|b|i|em|strong|code|kbd|sup|sub|details|summary|a|img|p|ul|ol|li|table|thead|tbody|tr|th|td)\b|!--)([A-Za-z][^<>\n]*)>/g, '&lt;$1&gt;');
        })
        .join('');
    })
    .join('\n');
}

function rewriteLinks(markdown, srcRel) {
  const srcDir = path.dirname(srcRel);
  let inFence = false;
  return markdown
    .split('\n')
    .map((line) => {
      if (/^\s*(```|~~~)/.test(line)) { inFence = !inFence; return line; }
      if (inFence) return line;
      return line.replace(/(?<!!)\]\(([^)\s]+)\)/g, (match, target) => {
        if (/^(https?:|mailto:|#|\/)/.test(target)) return match;
        const [file, hash] = target.split('#');
        const resolved = path.normalize(path.join(srcDir, file));
        const anchor = hash ? `#${hash}` : '';
        const route = routeOf.get(resolved);
        if (route) return `](${route}${anchor})`;
        const abs = path.join(root, resolved);
        if (resolved.startsWith('..') || !fs.existsSync(abs)) return `](${gh})`;
        const kind = fs.statSync(abs).isDirectory() ? 'tree' : 'blob';
        return `](${gh}/${kind}/${branch}/${resolved.split(path.sep).join('/')}${anchor})`;
      });
    })
    .join('\n');
}

fs.rmSync(out, { recursive: true, force: true });
let written = 0;
const skipped = [];
for (const [src, route] of pages) {
  const abs = path.isAbsolute(src) ? src : path.join(root, src);
  if (!fs.existsSync(abs)) { skipped.push(src); continue; }
  const srcRel = path.isAbsolute(src) ? path.join('docs', path.basename(src)) : src;
  let text = fs.readFileSync(abs, 'utf8');
  for (const [pattern, replacement] of redactions) text = text.replace(pattern, replacement);
  text = escapeOutsideCode(rewriteLinks(text, srcRel));
  const sourceUrl = path.isAbsolute(src) ? null : `${gh}/blob/${branch}/${src}`;
  const note = sourceUrl ? `::: info Quelle\nDieses Dokument wird beim Bauen der Seite aus [\`${src}\`](${sourceUrl}) übernommen.\n:::\n\n` : '';
  const heading = text.match(/^# .*$/m);
  text = heading ? text.replace(heading[0], `${heading[0]}\n\n${note}`.trimEnd() + '\n') : note + text;
  if (forbidden.test(text)) throw new Error(`${src}: contains an internal identifier (${text.match(forbidden)[0]})`);
  const target = path.join(out, route.replace(/^\//, '') + '.md');
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, text);
  written++;
}

// ADR index: the table from docs/README.md, links rewritten relative to docs/.
const readme = fs.readFileSync(path.join(root, 'docs/README.md'), 'utf8');
const adrStart = readme.indexOf('## ADR-Index');
if (adrStart >= 0) {
  let index = readme.slice(adrStart).replace('## ADR-Index', '# Architekturentscheidungen (ADR)');
  index = escapeOutsideCode(rewriteLinks(index, 'docs/README.md'));
  if (forbidden.test(index)) throw new Error('ADR index contains an internal identifier');
  fs.mkdirSync(path.join(out, 'adr'), { recursive: true });
  fs.writeFileSync(path.join(out, 'adr/index.md'), index);
  written++;
}
console.log(`sync-docs: ${written} pages written to docs-src/${skipped.length ? `; optional/missing skipped: ${skipped.join(', ')}` : ''}`);
