/**
 * Capture the README screenshots from a running TraceOps app.
 *
 *   cd TraceOps
 *   ./mxcli run --local -p TraceOps.mpr --ensure-db     # in another shell
 *   npm install --no-save playwright-core
 *   node scripts/capture-screenshots.js
 *
 * Renders at the prototype's 2560x1440 canvas but downsamples with
 * deviceScaleFactor so the committed PNGs stay small enough for a repo.
 */
const { chromium } = require('playwright-core');

const BASE = process.env.TRACEOPS_URL || 'http://127.0.0.1:8080';
const OUT = process.env.TRACEOPS_SHOTS || '../docs/screenshots';

const VIEWS = [
  ['/', 'cockpit'],
  ['/p/traceability', 'traceability'],
  ['/p/guardrails', 'guardrails'],
  ['/p/sessions', 'agent-sessions'],
  ['/p/validation', 'validation-queue'],
  ['/p/releases', 'releases'],
];

(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM || '/opt/pw-browsers/chromium',
    args: ['--no-sandbox'],
  });
  // The app declares min-width:2400px, so the viewport must be at least that
  // wide or the shell scrolls horizontally instead of laying out.
  const page = await browser.newPage({
    viewport: { width: 2560, height: 1440 },
    deviceScaleFactor: 0.75,
  });

  const errors = [];
  page.on('pageerror', (e) => errors.push(`${e.message}`.slice(0, 200)));

  for (const [path, name] of VIEWS) {
    await page.goto(BASE + path, { waitUntil: 'networkidle', timeout: 90000 });
    // Mendix hydrates its client after networkidle; without this the first
    // capture lands on the loading bar.
    await page.waitForSelector('.tr-app', { timeout: 30000 });
    await page.waitForTimeout(6000);
    await page.screenshot({ path: `${OUT}/${name}.png` });
    console.log(`captured ${name}`);
  }

  if (errors.length) console.log('page errors:\n' + errors.slice(0, 5).join('\n'));
  await browser.close();
})();
