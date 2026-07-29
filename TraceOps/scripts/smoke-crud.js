/**
 * Drive requirement create / edit / delete through the real UI and assert the
 * tree's derived data stays correct.
 *
 * The point is not that the form saves — it is that ACT_RecomputeTree rebuilds
 * Depth, Path, SortIndex, the rollups and the cell strings, so a new child shows
 * up in the right place and its ancestors' counts move.
 *
 *   node scripts/smoke-crud.js
 */
const { chromium } = require('playwright-core');

const BASE = process.env.TRACEOPS_URL || 'http://127.0.0.1:8080';
const NEW_ID = 'REQ-SMOKE-1';

const rowIds = (p) =>
  p.$$eval('.tr-tree-row .tr-reqid', (els) => els.map((e) => e.textContent.trim()));

const rowByIdCells = (p, id) =>
  p.evaluate((wanted) => {
    const row = [...document.querySelectorAll('.tr-tree-row')].find(
      (r) => r.querySelector('.tr-reqid')?.textContent.trim() === wanted
    );
    if (!row) return null;
    const cells = [...row.children].map((c) => c.textContent.trim());
    const depth = [...row.querySelector('.tr-reqcell').classList]
      .find((c) => /^tr-d\d$/.test(c))?.slice(4);
    return { depth, status: cells[1], artifacts: cells[3], tests: cells[4] };
  }, id);

const footer = (p) => p.$eval('.tr-panel-cta', (e) => e.textContent.trim()).catch(() => '?');

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

  await p.goto(`${BASE}/p/traceability`, { waitUntil: 'networkidle', timeout: 90000 });
  await p.waitForSelector('.tr-tree-row', { timeout: 30000 });
  await p.waitForTimeout(3000);

  // Start from a known shape.
  await p.click('.tr-btn-ghost:has-text("Collapse all")');
  await p.waitForTimeout(2500);
  const before = await rowIds(p);
  const beforeFooter = await footer(p);
  console.log(`baseline: ${before.length} roots, footer="${beforeFooter}"`);

  const mesBefore = await rowByIdCells(p, 'MES');
  console.log('MES before:', JSON.stringify(mesBefore));

  // --- CREATE a child of MES -------------------------------------------------
  // A Mendix popup page is a `.mx-window`; only its `.mx-window-content` child is
  // "visible" to Playwright (the window itself is position:fixed with no
  // offsetParent). A runtime *error* is a different beast — `.mx-dialog-error`.
  const DLG = '.mx-window-content';
  const openEditor = async () => {
    await p.waitForSelector(DLG, { timeout: 20000 });
    await p.waitForTimeout(2500);
  };
  const errorDialog = () =>
    p.$eval('.mx-dialog-error', (e) => e.innerText.replace(/\n/g, ' ')).catch(() => null);

  const mesRow = p.locator('.tr-tree-row', { has: p.locator('.tr-reqid', { hasText: /^MES$/ }) });
  await mesRow.locator('.tr-row-act').first().click();   // "+" = add child
  await openEditor();
  const err = await errorDialog();
  check('editor opens on add-child (no runtime error)', err === null, err || '');

  // Each field renders as `.mx-name-<widget>.form-group` wrapping its own <label>
  // and input, so target the wrapper by widget name rather than by label text.
  const setField = async (widget, value) => {
    const input = p.locator(`${DLG} .mx-name-${widget} input,
                             ${DLG} .mx-name-${widget} textarea`).first();
    await input.fill(String(value));
  };
  await setField('edReqId', NEW_ID);
  await setField('edTitleField', 'Smoke-test requirement');
  await setField('edArtifacts', 3);
  await setField('edPassed', 5);
  await p.click(`${DLG} button:has-text("Save")`);
  await p.waitForTimeout(6000);

  const created = await rowByIdCells(p, NEW_ID);
  check('new row appears in the tree', created !== null, JSON.stringify(created));
  check('new row is a child of MES (depth 1)', created?.depth === '1', `depth=${created?.depth}`);
  check('new row shows its artifact count', created?.artifacts === '3', `artifacts=${created?.artifacts}`);

  const mesAfter = await rowByIdCells(p, 'MES');
  const artBefore = parseInt(mesBefore.artifacts, 10);
  const artAfter = parseInt(mesAfter.artifacts, 10);
  check('MES artifact rollup grew by 3', artAfter === artBefore + 3,
        `${mesBefore.artifacts} -> ${mesAfter.artifacts}`);

  // --- EDIT: change a counter and confirm the cell and the rollup both move ---
  const newRow = p.locator('.tr-tree-row', { has: p.locator('.tr-reqid', { hasText: NEW_ID }) });
  await newRow.locator('.tr-row-act').nth(1).click();    // pencil = edit
  await openEditor();
  await setField('edArtifacts', 10);
  await p.click(`${DLG} button:has-text("Save")`);
  await p.waitForTimeout(5000);

  const edited = await rowByIdCells(p, NEW_ID);
  check('edited artifact count re-renders', edited?.artifacts === '10',
        `artifacts="${edited?.artifacts}"`);
  const mesEdited = await rowByIdCells(p, 'MES');
  check('MES rollup follows the edit', parseInt(mesEdited.artifacts, 10) === artBefore + 10,
        `${mesEdited?.artifacts} (expected ${artBefore + 10})`);

  // --- DELETE ----------------------------------------------------------------
  const row2 = p.locator('.tr-tree-row', { has: p.locator('.tr-reqid', { hasText: NEW_ID }) });
  await row2.locator('.tr-row-act').nth(1).click();
  await openEditor();
  await p.click(`${DLG} button:has-text("Delete")`);
  await p.waitForTimeout(5000);

  const gone = await rowByIdCells(p, NEW_ID);
  check('row is gone after delete', gone === null);

  const mesRestored = await rowByIdCells(p, 'MES');
  check('MES rollup returns to its original value', mesRestored?.artifacts === mesBefore.artifacts,
        `${mesRestored?.artifacts} vs ${mesBefore.artifacts}`);

  // Delete must take the subtree and nothing else. This caught a real one: the
  // walk originally marked rows with IsSelected — the denormalised row selection
  // — so every delete silently took the *selected* requirement's subtree too.
  await p.click('.tr-btn-ghost:has-text("Collapse all")');
  await p.waitForTimeout(2500);
  const after = await rowIds(p);
  check('delete removed nothing else', after.join(' ') === before.join(' '),
        `${after.join(' ')} vs ${before.join(' ')}`);

  console.log(fail.length ? `\n${fail.length} FAILED: ${fail.join(', ')}` : '\nall checks passed');
  await browser.close();
  process.exit(fail.length ? 1 : 0);
})();
