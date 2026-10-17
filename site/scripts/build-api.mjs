// Renders contracts/openapi.yaml as a standalone Redoc page into .vitepress/dist/api/index.html (after vitepress build).
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const siteDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const spec = path.resolve(siteDir, '../contracts/openapi.yaml');
const outFile = path.join(siteDir, '.vitepress/dist/api/index.html');
fs.mkdirSync(path.dirname(outFile), { recursive: true });
const bin = path.join(siteDir, 'node_modules/.bin/redocly');
execFileSync(bin, [
  'build-docs', spec, '-o', outFile,
  '--title', 'Timetrack API-Referenz',
  '--theme.openapi.theme.colors.primary.main=#2563EB',
  '--theme.openapi.theme.typography.fontFamily=system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
  '--theme.openapi.theme.typography.headings.fontFamily=system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
], { stdio: 'inherit' });
// Redoc links Google Fonts by default; the site is meant to work without third-party requests.
let html = fs.readFileSync(outFile, 'utf8');
html = html.replace(/<link[^>]*fonts\.googleapis\.com[^>]*>/g, '');
html = html.replace('<head>', '<head><link rel="icon" href="../logo.svg">');
if (/192\.168\.|\/Users\/|@icloud\.com/i.test(html)) throw new Error('API page contains an internal identifier');
html = html.replace('</body>', '<a href="../" style="position:fixed;right:12px;bottom:12px;z-index:100;background:#2563EB;color:#fff;padding:8px 14px;border-radius:999px;font:600 14px system-ui,sans-serif;text-decoration:none;box-shadow:0 2px 10px rgba(0,0,0,.25)">Zur Dokumentation</a></body>');
fs.writeFileSync(outFile, html);
console.log(`build-api: wrote ${path.relative(siteDir, outFile)} (${(html.length / 1024).toFixed(0)} KiB)`);
