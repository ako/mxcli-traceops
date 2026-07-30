/**
 * Smoke-test the traceability tree's expand / collapse behaviour against the
 * running app. Reports what a user actually sees, including the effect of the
 * ListView's 20-row page (see FINDINGS.md #17).
 *
 *   node scripts/smoke-tree.js
 */
const { chromium } = require('playwright-core');

/**
 * Reset the shared view state before asserting anything.
 *
 * AppState is a single global row, so an active search or filter chip persists
 * across page loads and across test runs — the same property that lets the app
 * remember your view. A test that assumes a clean tree has to say so.
 */
async function resetView(p) {
  const field = await p.$eval('.tr-search input', (e) => e.value).catch(() => '');
  if (field !== '') {
    await p.click('.tr-search-clear');
    await p.waitForTimeout(4000);
  }
  for (const chip of ['No implementation', 'No passing test', 'Violations', 'My requirements']) {
    const on = await p.$$eval('.tr-filter', (els, label) =>
      els.some((e) => e.textContent.includes(label) && e.className.includes('tr-filter--on')), chip);
    if (on) {
      await p.click(`.tr-filter:has-text("${chip}")`);
      await p.waitForTimeout(3000);
    }
  }
}


const BASE = process.env.TRACEOPS_URL || 'http://127.0.0.1:8080';

const rows = (p) =>
  p.$$eval('.tr-tree-row', (els) =>
    els.map((e) => ({
      id: e.querySelector('.tr-reqid')?.textContent.trim(),
      caret: e.querySelector('.tr-caret')?.textContent.trim(),
      depth: [...e.querySelector('.tr-reqcell').classList]
        .find((c) => /^tr-d\d$/.test(c))
        ?.slice(4),
    }))
  );

const footer = (p) =>
  p.$eval('.tr-panel-cta', (e) => e.textContent.trim()).catch(() => '(none)');

const hasLoadMore = (p) =>
  p.evaluate(() => !!document.querySelector('.mx-listview-loadMore'));

(async () => {
  const b = await chromium.launch({
    executablePath: process.env.CHROMIUM || '/opt/pw-browsers/chromium',
    args: ['--no-sandbox'],
  });
  const p = await b.newPage({ viewport: { width: 2560, height: 1440 } });
  await p.goto(`${BASE}/p/traceability`, { waitUntil: 'networkidle', timeout: 90000 });
  await p.waitForSelector('.tr-tree-row', { timeout: 30000 });
  await p.waitForTimeout(3000);
  await resetView(p);

  const show = async (label) => {
    const r = await rows(p);
    console.log(
      `${label.padEnd(26)} rendered=${String(r.length).padStart(2)}  ` +
        `loadMore=${await hasLoadMore(p)}  footer="${await footer(p)}"`
    );
    return r;
  };

  const initial = await show('initial');
  console.log('  first 6:', initial.slice(0, 6).map((r) => `${r.caret || '·'}${r.id}@d${r.depth}`).join(' '));

  // Collapse all → only the six epic roots should remain.
  await p.click('.tr-btn-ghost:has-text("Collapse all")');
  await p.waitForTimeout(2500);
  const collapsed = await show('after Collapse all');
  console.log('  roots:', collapsed.map((r) => r.id).join(' '));

  // Expand one root by clicking its caret.
  await p.click('.tr-tree-row .tr-caret');
  await p.waitForTimeout(2500);
  const oneOpen = await show('after expanding MES');
  console.log('  now:', oneOpen.map((r) => `${r.caret || '·'}${r.id}`).join(' '));

  // Expand all → every node with children opens.
  await p.click('.tr-btn-ghost:has-text("Expand all")');
  await p.waitForTimeout(3500);
  await show('after Expand all');

  // Restore the collapsed-ish default so the app is left tidy.
  await p.click('.tr-btn-ghost:has-text("Collapse all")');
  await p.waitForTimeout(2000);

  await b.close();
})();
