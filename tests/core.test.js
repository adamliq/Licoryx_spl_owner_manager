const test = require('node:test');
const assert = require('node:assert');
const core = require('../splunk_app/licoryx_spl_owner_manager/appserver/static/lookup_owner_core.js');

const sample = {
  entry: [
    { name: 'assets.csv', links: { alternate: '/servicesNS/nobody/search/data/lookup-table-files/assets.csv', acl: '/servicesNS/nobody/search/data/lookup-table-files/assets.csv/acl' },
      acl: { app: 'search', owner: 'alice', sharing: 'app', perms: { read: ['*'], write: ['admin', 'power'] } } },
    { name: 'ids.csv', links: { alternate: '/servicesNS/bob/sec/data/lookup-table-files/ids.csv', acl: '/servicesNS/bob/sec/data/lookup-table-files/ids.csv/acl' },
      acl: { app: 'sec', owner: 'bob', sharing: 'user', perms: null } },
    { name: 'geo_assets.csv', links: { alternate: '/servicesNS/nobody/sec/data/lookup-table-files/geo_assets.csv', acl: '/servicesNS/nobody/sec/data/lookup-table-files/geo_assets.csv/acl' },
      acl: { app: 'sec', owner: 'nobody', sharing: 'global', perms: { read: ['*'], write: ['admin'] } } }
  ]
};
const rows = core.parseLookups(sample);
const users = new Set(['alice', 'carol']);

test('parseLookups flattens ACL', () => {
  assert.strictEqual(rows.length, 3);
  assert.deepStrictEqual(rows[0].writePerms, ['admin', 'power']);
  assert.deepStrictEqual(rows[1].readPerms, []);
  assert.match(rows[0].aclPath, /\/acl$/);
});

test('orphan detection', () => {
  assert.strictEqual(core.isOrphan(rows[0], users), false);
  assert.strictEqual(core.isOrphan(rows[1], users), true);
  assert.strictEqual(core.isOrphan(rows[2], users), false, 'nobody is never orphaned');
  assert.strictEqual(core.isOrphan(rows[1], null), false, 'unknown user list');
});

test('filters', () => {
  const names = (f) => core.applyFilters(rows, f, users).map((r) => r.name);
  assert.deepStrictEqual(names({ name: 'ASSETS' }), ['assets.csv', 'geo_assets.csv']);
  assert.deepStrictEqual(names({ name: 'a*.csv' }), ['assets.csv']);
  assert.deepStrictEqual(names({ apps: ['sec'] }), ['ids.csv', 'geo_assets.csv']);
  assert.deepStrictEqual(names({ sharing: ['app', 'global'] }), ['assets.csv', 'geo_assets.csv']);
  assert.deepStrictEqual(names({ orphanOnly: true }), ['ids.csv']);
  assert.deepStrictEqual(names({ name: 'a.c' }), [], 'dot is literal in wildcard mode');
});

test('ACL body keeps sharing and perms', () => {
  assert.deepStrictEqual(core.buildAclBody(rows[0], 'carol'),
    { owner: 'carol', sharing: 'app', 'perms.read': '*', 'perms.write': 'admin,power' });
  assert.deepStrictEqual(core.buildAclBody(rows[1], 'carol'), { owner: 'carol', sharing: 'user' });
});

test('block reasons', () => {
  assert.strictEqual(core.blockReason(rows[0], 'carol'), null);
  assert.match(core.blockReason(rows[0], 'alice'), /Already owned/);
  assert.match(core.blockReason(rows[1], 'carol'), /Private/);
  assert.strictEqual(core.blockReason(rows[1], 'carol', { allowPrivate: true }), null);
  assert.match(core.blockReason(rows[0], ''), /No new owner/);
});

test('CSV escapes quotes and formula injection', () => {
  const csv = core.toCsv([{ name: '=cmd|"x"', app: 'a,b', owner: 'o', sharing: 'app', readPerms: ['*'], writePerms: [] }], null);
  assert.ok(csv.includes('"\'=cmd|""x"""'));
  assert.ok(csv.includes('"a,b"'));
});

test('escapeHtml', () => {
  assert.strictEqual(core.escapeHtml('<img src=x onerror="a">'), '&lt;img src=x onerror=&quot;a&quot;&gt;');
});

test('runLimited respects concurrency and order', async () => {
  let active = 0, peak = 0;
  const out = await new Promise((resolve) => core.runLimited([1, 2, 3, 4, 5], 2, (n, done) => {
    active++; peak = Math.max(peak, active);
    setTimeout(() => { active--; done(n * 10); }, 5 * (6 - n));
  }, null, resolve));
  assert.deepStrictEqual(out, [10, 20, 30, 40, 50]);
  assert.strictEqual(peak, 2);
});

test('errorMessage', () => {
  assert.strictEqual(core.errorMessage({ status: 403, data: { messages: [{ text: 'nope' }] } }), 'nope');
  assert.match(core.errorMessage({ status: 403 }), /Forbidden/);
});
