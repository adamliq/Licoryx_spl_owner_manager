// End-to-end checks of the app in Splunk Web (Playwright).
// Usage: node tests/docker/e2e.js <user> <password> <scenario> [outdir]
// scenarios: view | bulk-orphans | private | non-owner
const { chromium } = require('playwright');
const [user, pass, scenario, out = '.'] = process.argv.slice(2);
const BASE = process.env.SPLUNK_WEB || 'http://localhost:8000';
const PAGE = BASE + '/en-US/app/licoryx_spl_owner_manager/lookup_owners';

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });
  const errors = [];
  page.on('pageerror', (e) => errors.push('pageerror: ' + e.message));
  page.on('dialog', (d) => { errors.push('DIALOG: ' + d.message()); d.dismiss(); });

  await page.goto(BASE + '/en-US/account/login');
  await page.fill('#username', user);
  await page.fill('#password', pass);
  await page.click('input[type=submit]');
  await page.waitForURL((u) => !u.pathname.includes('/account/login'), { timeout: 30000 });

  await page.goto(PAGE);
  await page.waitForSelector('.lom-table tbody tr', { timeout: 60000 });
  await page.waitForFunction(() => !/Loading/.test(document.querySelector('.lom-banner').textContent || ''), null, { timeout: 30000 });
  const info = async () => ({
    badge: await page.textContent('.lom-badge'),
    banner: (await page.textContent('.lom-banner')).trim(),
    count: await page.textContent('.lom-count'),
    rows: await page.$$eval('.lom-table tbody tr', (trs) => trs.map((tr) =>
      [...tr.querySelectorAll('td')].slice(1, 5).map((td) => td.textContent.trim()).join(' | ')))
  });
  const log = (label, v) => console.log(label + ': ' + JSON.stringify(v, null, 1));

  async function change(owner) {
    await page.click('.lom-change');
    await page.fill('.lom-new-owner', owner);
    if (await page.$('.lom-confirm-count')) {
      await page.fill('.lom-confirm-count', String(await page.$$eval('.lom-row:checked', (x) => x.length)));
    }
    log('preview', await page.$$eval('.lom-preview tbody tr', (trs) => trs.map((t) => t.textContent)));
    await page.screenshot({ path: `${out}/${user}-${scenario}-modal.png` });
    if (await page.isDisabled('.lom-confirm')) { log('confirm', 'disabled'); await page.click('.lom-cancel'); return; }
    await page.click('.lom-confirm');
    await page.waitForFunction(() => {
      const h = document.querySelector('.lom-results h3'); return h && h.textContent === 'Results';
    }, null, { timeout: 60000 });
    await page.waitForTimeout(2000);
    log('results', await page.$$eval('.lom-results tr', (trs) => trs.map((t) => t.textContent)));
  }

  const selectByName = async (name) => {
    await page.fill('.lom-f-name', name);
    await page.waitForTimeout(400);
    await page.check('.lom-select-page');
  };

  log('initial', await info());
  if (scenario === 'bulk-orphans') {
    await page.check('.lom-f-orphan');
    log('orphan filter', await info());
    await page.check('.lom-select-page');
    await change('carol');
    log('after', await info());
  } else if (scenario === 'private') {
    await selectByName('bob_private.csv');
    await change('carol');                       // spike O1: file moves to carol
  } else if (scenario === 'non-owner') {
    await selectByName('bob_app.csv');
    await change('alice');                        // spike O2
  }
  await page.screenshot({ path: `${out}/${user}-${scenario}.png`, fullPage: true });
  log('errors', errors);
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
