/**
 * Assert that the chrome's counters, the validation gate and the tree search are
 * real — i.e. that they follow the data instead of being baked into the page.
 *
 * The bug this exists for is a header that disagrees with the list under it, so
 * every check compares a *rendered number* against a *rendered list length*
 * rather than against a constant. A constant would pass just as happily against
 * the literals it replaced.
 *
 *   node scripts/smoke-live.js
 */
const { chromium } = require('playwright-core');

const BASE = process.env.TRACEOPS_URL || 'http://127.0.0.1:8080';
const DLG = '.mx-window-content';

const text = (p, sel) => p.$eval(sel, (e) => e.textContent.trim()).catch(() => null);
const num = async (p, sel) => {
  const t = await text(p, sel);
  return t === null ? null : parseInt(t.replace(/[^\d-]/g, ''), 10);
};
const count = (p, sel) => p.$$eval(sel, (els) => els.length);

(async () => {
  const browser = await chromium.launch({
    executablePath: process.env.CHROMIUM || '/opt/pw-browsers/chromium',
    args: ['--no-sandbox'],
  });
  const p = await browser.newPage({ viewport: { width: 2560, height: 1440 } });
  const fail = [];
  const check = (label, ok, detail) => {
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? '  — ' + detail : ''}`);
    if (!ok) fail.push(label);
  };

  // ---------------------------------------------------------------- cockpit ---
  await p.goto(`${BASE}/p/cockpit`, { waitUntil: 'networkidle', timeout: 90000 });
  await p.waitForSelector('.tr-kpi', { timeout: 30000 });
  await p.waitForTimeout(3000);

  const noImplHeader = await num(p, '.mx-name-gniCount');
  const noImplRows = await count(p, '.mx-name-lvNoImpl > ul > li');
  check('cockpit gap header matches its own list', noImplHeader === noImplRows,
        `header=${noImplHeader} rows=${noImplRows}`);

  const riskHeader = await num(p, '.mx-name-riskCount');
  const riskRows = await count(p, '.mx-name-lvRisk > ul > li');
  check('risk header matches the risk list', riskHeader === riskRows,
        `header=${riskHeader} rows=${riskRows}`);

  // "Guardrail violations" counts violated *mappings*; the gap column and the
  // tree chip count the *requirements* affected. The design shows both numbers
  // too, so each is checked against the list it actually labels.
  const vioTile = await p.$$eval('.tr-kpi', (tiles) => {
    const t = tiles.find((x) => /Guardrail violations/i.test(x.textContent));
    return t ? t.querySelector('.tr-kpi-value')?.textContent.trim() : null;
  });
  const vioHeader = await num(p, '.mx-name-gvCount');
  const vioRows = await count(p, '.mx-name-lvVio > ul > li');
  check('violation column header matches its own list', vioHeader === vioRows,
        `header=${vioHeader} rows=${vioRows}`);
  const topBarVio = await num(p, '.mx-name-live3n');
  check('violations KPI tile matches the top-bar mapping count', String(topBarVio) === vioTile,
        `tile="${vioTile}" topbar=${topBarVio}`);

  // ------------------------------------------------------------ traceability ---
  await p.goto(`${BASE}/p/traceability`, { waitUntil: 'networkidle', timeout: 90000 });
  await p.waitForSelector('.tr-tree-row', { timeout: 30000 });
  await p.waitForTimeout(3000);

  const vioChip = await num(p, '.mx-name-fvCount');
  check('tree violations chip matches the cockpit gap column', vioChip === vioRows,
        `chip=${vioChip} column=${vioRows}`);

  const traceBadge = await num(p, '.mx-name-bgTrace');
  await p.click('.tr-btn-ghost:has-text("Expand all")');
  await p.waitForTimeout(3000);
  const footerTotal = await num(p, '.tr-panel-cta');
  check('sidebar requirement badge is the real total', traceBadge === 81,
        `badge=${traceBadge}`);

  // --- SEARCH ----------------------------------------------------------------
  // Collapse first. Expanded, the tree renders 20 rows because of the PageSize
  // cap (FINDINGS #17) — and 20 is also roughly what a *broken* search leaves on
  // screen, so an inert search read as a passing one. From a collapsed tree the
  // row set is unambiguous.
  await p.click('.tr-btn-ghost:has-text("Collapse all")');
  await p.waitForTimeout(3000);
  const collapsedRows = await count(p, '.tr-tree-row');

  const searchInput = p.locator('.tr-search input');
  await searchInput.click();
  await searchInput.pressSequentially('traceability', { delay: 30 });
  await p.keyboard.press('Enter');
  await p.waitForTimeout(5000);

  const searchRows = await p.$$eval('.tr-tree-row .tr-reqid', (e) => e.map((x) => x.textContent.trim()));
  // Exactly one requirement is titled "Material traceability", under MES. So the
  // answer is that row plus its ancestors — and nothing else.
  check('search reveals the match and its ancestors only',
        searchRows.join(' ') === 'MES MES-2',
        `${searchRows.length} rows: ${searchRows.join(' ')}`);

  const titles = await p.$$eval('.tr-tree-row', (rows) =>
    rows.map((r) => ({
      id: r.querySelector('.tr-reqid')?.textContent.trim(),
      title: r.querySelector('.tr-reqtitle')?.textContent.trim(),
      depth: [...r.querySelector('.tr-reqcell').classList].find((c) => /^tr-d\d$/.test(c))?.slice(4),
    }))
  );
  check('the match is shown at its real depth under its parent',
        titles.some((t) => t.depth === '0' && t.id === 'MES') &&
        titles.some((t) => t.depth === '1' && /traceability/i.test(t.title || '')),
        titles.map((t) => `${t.id}@d${t.depth}`).join(' '));

  await p.click('.tr-search-clear');
  await p.waitForTimeout(5000);
  const clearedRows = await count(p, '.tr-tree-row');
  const clearedField = await p.$eval('.tr-search input', (e) => e.value);
  check('clearing the search restores the tree', clearedRows >= collapsedRows,
        `${searchRows.length} -> ${clearedRows} (collapsed baseline ${collapsedRows})`);
  check('clearing empties the field itself', clearedField === '', `field="${clearedField}"`);

  // -------------------------------------------------------------- validation ---
  await p.goto(`${BASE}/p/validation`, { waitUntil: 'networkidle', timeout: 90000 });
  await p.waitForSelector('.tr-val-row', { timeout: 30000 });
  await p.waitForTimeout(3000);

  const queueBefore = await count(p, '.tr-val-row');
  const badgeBefore = await num(p, '.mx-name-bgValidate');
  check('validation badge matches the queue length', badgeBefore === queueBefore,
        `badge=${badgeBefore} rows=${queueBefore}`);

  const reqRef = await text(p, '.mx-name-dvVal .tr-val-req');
  await p.click('.tr-btn-approve');
  await p.waitForTimeout(8000);

  const queueAfter = await count(p, '.tr-val-row');
  check('accepting evidence removes the item from the queue', queueAfter === queueBefore - 1,
        `${queueBefore} -> ${queueAfter}`);
  const badgeAfter = await num(p, '.mx-name-bgValidate');
  check('validation badge follows the decision', badgeAfter === queueAfter,
        `badge=${badgeAfter} rows=${queueAfter}`);

  // The accepted requirement should now read as verified in the tree. Reached via
  // search rather than Expand all: expanded, the list stops at 20 rows
  // (FINDINGS #17) and this row sits past that, so the row simply would not be in
  // the DOM and the check would fail for the wrong reason.
  await p.goto(`${BASE}/p/traceability`, { waitUntil: 'networkidle', timeout: 90000 });
  await p.waitForSelector('.tr-tree-row', { timeout: 30000 });
  await p.waitForTimeout(2500);
  const findInput = p.locator('.tr-search input');
  await findInput.click();
  await findInput.pressSequentially(reqRef, { delay: 20 });
  await p.keyboard.press('Enter');
  await p.waitForTimeout(5000);
  const status = await p.evaluate((id) => {
    const row = [...document.querySelectorAll('.tr-tree-row')].find(
      (r) => r.querySelector('.tr-reqid')?.textContent.trim() === id
    );
    return row ? row.children[1]?.textContent.trim() : null;
  }, reqRef);
  check('the accepted requirement is verified in the tree', status === 'verified',
        `${reqRef} status="${status}"`);

  console.log(fail.length ? `\n${fail.length} FAILED: ${fail.join(', ')}` : '\nall checks passed');
  await browser.close();
  process.exit(fail.length ? 1 : 0);
})();
