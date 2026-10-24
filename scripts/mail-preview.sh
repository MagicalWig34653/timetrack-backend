#!/usr/bin/env bash
# Dev only: renders all mail templates to HTML/text files and optionally screenshots them (light, dark, narrow).
#   scripts/mail-preview.sh [output-dir]            render only (default: .build/mail-preview)
#   MAIL_PREVIEW_SHOTS=1 scripts/mail-preview.sh    additionally screenshot with Playwright (needs `npm i playwright`
#                                                   somewhere; set PLAYWRIGHT_DIR to that folder)
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-.build/mail-preview}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
MAIL_PREVIEW_DIR="$out" swift test --no-parallel --filter MailTemplateTests/testWritePreviews
echo "Rendered to $out"
if [ "${MAIL_PREVIEW_SHOTS:-}" = "1" ]; then
  pw="${PLAYWRIGHT_DIR:?set PLAYWRIGHT_DIR to a folder with the playwright npm package}"
  PLAYWRIGHT_DIR="$pw" OUT="$out" node --input-type=module -e '
    import { createRequire } from "node:module";
    const { chromium } = createRequire(process.env.PLAYWRIGHT_DIR + "/")("playwright");
    import("node:fs").then(async ({ readdirSync }) => {
      const browser = await chromium.launch();
      for (const file of readdirSync(process.env.OUT).filter(f => f.endsWith(".html"))) {
        for (const [label, scheme, width] of [["light", "light", 720], ["dark", "dark", 720], ["narrow-light", "light", 360], ["narrow-dark", "dark", 360]]) {
          const page = await browser.newPage({ colorScheme: scheme, viewport: { width, height: 900 } });
          await page.goto("file://" + process.env.OUT + "/" + file);
          await page.screenshot({ path: `${process.env.OUT}/${file.replace(".html", "")}-${label}.png`, fullPage: true });
          await page.close();
        }
      }
      await browser.close();
    });
  '
fi
