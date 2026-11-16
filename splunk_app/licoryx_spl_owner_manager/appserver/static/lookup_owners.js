/*
 * Lookup Owner Manager - dashboard controller.
 *
 * Every REST call goes through Splunk Web with the logged-in user's
 * session (splunkjs service adds the CSRF form key). Nothing here runs
 * server-side or with elevated privileges: Splunk decides what is allowed.
 */
require([
    'jquery',
    'splunkjs/mvc',
    '../app/licoryx_spl_owner_manager/lookup_owner_core',
    'splunkjs/mvc/simplexml/ready!'
], function ($, mvc, core) {
    'use strict';

    var CONCURRENCY = 3;
    var PAGE_SIZES = [25, 50, 100];
    var service = mvc.createService({ owner: 'nobody' });
    var esc = core.escapeHtml;

    var state = {
        user: null,
        caps: [],
        canChange: false,
        rows: [],
        users: null,       // array of names, or null if not readable
        userSet: null,
        filtered: [],
        selected: {},      // id -> row
        sortKey: 'name',
        sortDir: 'asc',
        page: 0,
        pageSize: 50,
        filters: { name: '', apps: [], owners: [], sharing: [], orphanOnly: false },
        lastResults: null
    };

    // ---------- REST helpers ----------

    function get(path, params) {
        var d = $.Deferred();
        service.get(path, $.extend({ output_mode: 'json' }, params || {}), function (err, res) {
            if (err) d.reject(err); else d.resolve(res.data);
        });
        return d.promise();
    }

    function post(path, body, cb) {
        // No output_mode here: the ACL handler rejects unknown arguments.
        service.post(path, body, function (err) { cb(err || null); });
    }

    // ---------- Layout ----------

    var $root = $('#lom-root');
    $root.html([
        '<div class="lom-header">',
        '  <div><span class="lom-title">Lookup owners</span> <span class="lom-who"></span></div>',
        '  <div><span class="lom-badge"></span> <button class="btn lom-refresh">Refresh</button></div>',
        '</div>',
        '<div class="lom-banner" hidden></div>',
        '<div class="lom-filters">',
        '  <label>Name<input type="text" class="lom-f-name" placeholder="e.g. *_assets.csv"></label>',
        '  <label>App<select multiple class="lom-f-apps"></select></label>',
        '  <label>Owner<select multiple class="lom-f-owners"></select></label>',
        '  <fieldset><legend>Sharing</legend>',
        '    <label><input type="checkbox" class="lom-f-sharing" value="user"> Private</label>',
        '    <label><input type="checkbox" class="lom-f-sharing" value="app"> App</label>',
        '    <label><input type="checkbox" class="lom-f-sharing" value="global"> Global</label>',
        '  </fieldset>',
        '  <label class="lom-orphan-wrap"><input type="checkbox" class="lom-f-orphan"> Orphaned only</label>',
        '  <button class="btn lom-clear">Clear filters</button>',
        '</div>',
        '<div class="lom-actions">',
        '  <span class="lom-count"></span>',
        '  <button class="btn btn-primary lom-change" disabled>Change owner…</button>',
        '  <button class="btn lom-export">Export CSV</button>',
        '  <label>Rows <select class="lom-pagesize"></select></label>',
        '</div>',
        '<table class="table table-chrome lom-table">',
        '  <thead><tr>',
        '    <th><input type="checkbox" class="lom-select-page" title="Select page"></th>',
        '    <th data-key="name">Name</th><th data-key="app">App</th>',
        '    <th data-key="owner">Owner</th><th data-key="sharing">Sharing</th>',
        '    <th>Read</th><th>Write</th>',
        '  </tr></thead><tbody></tbody>',
        '</table>',
        '<div class="lom-pager"></div>',
        '<div class="lom-results" hidden></div>',
        '<div class="lom-modal" hidden><div class="lom-modal-body"></div></div>'
    ].join(''));

    PAGE_SIZES.forEach(function (n) {
        $root.find('.lom-pagesize').append($('<option>').val(n).text(n).prop('selected', n === state.pageSize));
    });

    function banner(msg, kind) {
        var $b = $root.find('.lom-banner');
        if (!msg) { $b.attr('hidden', true).empty(); return; }
        $b.removeAttr('hidden').attr('class', 'lom-banner lom-banner-' + (kind || 'info')).text(msg);
    }

    // ---------- Loading ----------

    function load() {
        banner('Loading…');
        state.selected = {};
        var ctx = get('/services/authentication/current-context').then(function (d) {
            var c = (d.entry && d.entry[0] && d.entry[0].content) || {};
            state.user = c.username;
            state.caps = c.capabilities || [];
        });
        var lookups = get('/servicesNS/-/-/data/lookup-table-files', { count: 0 }).then(function (d) {
            state.rows = core.parseLookups(d);
        });
        // Users are optional. Without edit_user, splunkd returns only the
        // caller's own account, which would make every other owner look
        // orphaned, so the list is ignored in that case.
        var users = $.Deferred();
        get('/services/authentication/users', { count: 0, f: 'title' }).then(
            function (d) { users.resolve(core.parseUsers(d)); },
            function () { users.resolve(null); }
        );

        $.when(ctx, lookups, users).then(function (a, b, userList) {
            var full = userList && core.hasCapability(state.caps, 'edit_user');
            state.users = full ? userList : null;
            state.userSet = full ? new Set(userList) : null;
            state.canChange = core.hasCapability(state.caps, 'admin_all_objects');
            renderHeader();
            populateFilterOptions();
            banner(state.users ? null :
                'You cannot list users, so the orphan filter is off and the new owner must be typed in.', 'warn');
            refresh();
        }, function (err) {
            banner('Failed to load lookups: ' + core.errorMessage(err), 'error');
        });
    }

    function renderHeader() {
        $root.find('.lom-who').text('as ' + (state.user || '?'));
        $root.find('.lom-badge')
            .attr('class', 'lom-badge ' + (state.canChange ? 'lom-badge-ok' : 'lom-badge-ro'))
            .text(state.canChange ? 'Can change owners' : 'Read-only (no admin_all_objects)')
            .attr('title', 'A hint only. Splunk enforces permissions on every change.');
        $root.find('.lom-orphan-wrap').toggle(!!state.userSet);
    }

    function fillSelect($sel, values, chosen) {
        $sel.empty();
        values.forEach(function (v) {
            $sel.append($('<option>').val(v).text(v).prop('selected', chosen.indexOf(v) !== -1));
        });
    }

    function uniq(list) {
        return Array.from(new Set(list)).sort();
    }

    function populateFilterOptions() {
        fillSelect($root.find('.lom-f-apps'), uniq(state.rows.map(function (r) { return r.app; })), state.filters.apps);
        fillSelect($root.find('.lom-f-owners'), uniq(state.rows.map(function (r) { return r.owner; })), state.filters.owners);
    }

    // ---------- Filtering / rendering ----------

    function readFilters() {
        state.filters = {
            name: $root.find('.lom-f-name').val(),
            apps: $root.find('.lom-f-apps').val() || [],
            owners: $root.find('.lom-f-owners').val() || [],
            sharing: $root.find('.lom-f-sharing:checked').map(function () { return this.value; }).get(),
            orphanOnly: $root.find('.lom-f-orphan').is(':checked')
        };
    }

    function refresh() {
        state.filtered = core.sortRows(core.applyFilters(state.rows, state.filters, state.userSet),
            state.sortKey, state.sortDir);
        var maxPage = Math.max(0, Math.ceil(state.filtered.length / state.pageSize) - 1);
        if (state.page > maxPage) state.page = maxPage;
        renderTable();
    }

    function selectedRows() {
        return Object.keys(state.selected).map(function (k) { return state.selected[k]; });
    }

    function renderTable() {
        var start = state.page * state.pageSize;
        var pageRows = state.filtered.slice(start, start + state.pageSize);
        var html = pageRows.map(function (r) {
            var orphan = core.isOrphan(r, state.userSet);
            return '<tr data-id="' + esc(r.id) + '">' +
                '<td><input type="checkbox" class="lom-row"' + (state.selected[r.id] ? ' checked' : '') + '></td>' +
                '<td>' + esc(r.name) + '</td><td>' + esc(r.app) + '</td>' +
                '<td>' + esc(r.owner) + (orphan ? ' <span class="lom-tag-orphan">orphaned</span>' : '') + '</td>' +
                '<td>' + esc(r.sharing) + '</td>' +
                '<td>' + esc(r.readPerms.join(', ')) + '</td><td>' + esc(r.writePerms.join(', ')) + '</td>' +
                '</tr>';
        }).join('');
        $root.find('.lom-table tbody').html(html || '<tr><td colspan="7" class="lom-empty">No lookups match the filters.</td></tr>');

        $root.find('.lom-table th[data-key]').each(function () {
            var k = $(this).data('key');
            $(this).toggleClass('lom-sorted', k === state.sortKey)
                .attr('data-dir', k === state.sortKey ? state.sortDir : null);
        });
        $root.find('.lom-select-page').prop('checked',
            pageRows.length > 0 && pageRows.every(function (r) { return state.selected[r.id]; }));

        var n = state.filtered.length;
        var sel = selectedRows().length;
        $root.find('.lom-count').text(
            (n ? 'Showing ' + (start + 1) + '–' + Math.min(n, start + state.pageSize) + ' of ' + n : '0 lookups') +
            ' (' + state.rows.length + ' total)' + (sel ? ' · ' + sel + ' selected' : ''));
        $root.find('.lom-change').prop('disabled', sel === 0);

        var pages = Math.ceil(n / state.pageSize);
        $root.find('.lom-pager').html(pages > 1 ?
            '<button class="btn lom-prev"' + (state.page === 0 ? ' disabled' : '') + '>‹ Prev</button> ' +
            'Page ' + (state.page + 1) + ' of ' + pages +
            ' <button class="btn lom-next"' + (state.page >= pages - 1 ? ' disabled' : '') + '>Next ›</button>' : '');
    }

    // ---------- Change owner modal ----------

    function openModal() {
        var rows = selectedRows();
        var userOpts = (state.users || []).concat([core.NOBODY]).map(function (u) {
            return '<option value="' + esc(u) + '">';
        }).join('');
        var hasPrivate = rows.some(function (r) { return r.sharing === 'user'; });
        $root.find('.lom-modal-body').html(
            '<h3>Change owner of ' + rows.length + ' lookup' + (rows.length === 1 ? '' : 's') + '</h3>' +
            '<label>New owner <input type="text" class="lom-new-owner" list="lom-users" autocomplete="off"></label>' +
            '<datalist id="lom-users">' + userOpts + '</datalist>' +
            (hasPrivate ? '<p class="lom-warn">Some lookups are private. Splunk moves a private lookup into the new ' +
                'owner\'s private space: the new owner gets it and the previous owner loses access to it.</p>' : '') +
            '<div class="lom-preview"></div>' +
            (rows.length > 1 ? '<label>Type <b>' + rows.length + '</b> to confirm <input type="text" class="lom-confirm-count" size="6"></label>' : '') +
            '<div class="lom-modal-actions"><button class="btn lom-cancel">Cancel</button> ' +
            '<button class="btn btn-primary lom-confirm" disabled>Change owner</button></div>');
        $root.find('.lom-modal').removeAttr('hidden');
        updatePreview();
        $root.find('.lom-new-owner').trigger('focus');
    }

    function modalOpts() {
        return { owner: $.trim($root.find('.lom-new-owner').val() || '') };
    }

    function updatePreview() {
        var o = modalOpts();
        var rows = selectedRows();
        var ok = 0;
        var html = '<table class="table"><thead><tr><th>Lookup</th><th>App</th><th>Change</th></tr></thead><tbody>' +
            rows.map(function (r) {
                var why = core.blockReason(r, o.owner);
                if (!why) ok++;
                return '<tr' + (why ? ' class="lom-skip"' : '') + '><td>' + esc(r.name) + '</td><td>' + esc(r.app) + '</td><td>' +
                    (why ? 'Skipped: ' + esc(why) : esc(r.owner) + ' → ' + esc(o.owner)) + '</td></tr>';
            }).join('') + '</tbody></table>';
        $root.find('.lom-preview').html(html);
        var countOk = rows.length <= 1 || $.trim($root.find('.lom-confirm-count').val()) === String(rows.length);
        $root.find('.lom-confirm').prop('disabled', ok === 0 || !countOk).text('Change owner (' + ok + ')');
    }

    function closeModal() {
        $root.find('.lom-modal').attr('hidden', true);
    }

    function execute() {
        var o = modalOpts();
        var rows = selectedRows();
        var todo = [], results = [];
        rows.forEach(function (r) {
            var why = core.blockReason(r, o.owner);
            if (why) results.push({ row: r, ok: false, skipped: true, msg: why });
            else todo.push(r);
        });
        closeModal();
        showResults(results, todo.length, o.owner);

        core.runLimited(todo, CONCURRENCY, function (r, done) {
            post(r.aclPath, core.buildAclBody(r, o.owner), function (err) {
                done({ row: r, ok: !err, msg: err ? core.errorMessage(err) : 'Owner changed to ' + o.owner });
            });
        }, function (res) {
            results.push(res);
            showResults(results, todo.length, o.owner);
        }, function () {
            state.lastResults = { results: results, owner: o.owner };
            showResults(results, 0, o.owner, true);
            load(); // re-read what Splunk actually has
        });
    }

    function showResults(results, pending, owner, finished) {
        var ok = results.filter(function (r) { return r.ok; }).length;
        var failed = results.filter(function (r) { return !r.ok && !r.skipped; }).length;
        var skipped = results.filter(function (r) { return r.skipped; }).length;
        var $r = $root.find('.lom-results').removeAttr('hidden');
        $r.html('<h3>Results' + (finished ? '' : ' (running…)') + '</h3>' +
            '<p>' + ok + ' changed, ' + failed + ' failed, ' + skipped + ' skipped' + (finished ? '' : '') + '.' +
            (finished && failed ? ' <button class="btn lom-retry">Retry failed</button>' : '') +
            ' <button class="btn lom-dismiss">Dismiss</button></p>' +
            '<table class="table"><tbody>' + results.map(function (r) {
                return '<tr class="' + (r.ok ? 'lom-ok' : r.skipped ? 'lom-skip' : 'lom-fail') + '"><td>' +
                    esc(r.row.app) + ' / ' + esc(r.row.name) + '</td><td>' + esc(r.msg) + '</td></tr>';
            }).join('') + '</tbody></table>');
    }

    function retryFailed() {
        var last = state.lastResults;
        if (!last) return;
        var failedKeys = {};
        last.results.forEach(function (r) {
            if (!r.ok && !r.skipped) failedKeys[r.row.app + '\u0000' + r.row.name + '\u0000' + r.row.owner] = true;
        });
        // Rows were reloaded; pick fresh copies so the ACL body uses current values.
        state.selected = {};
        state.rows.forEach(function (r) {
            if (failedKeys[r.app + '\u0000' + r.name + '\u0000' + r.owner]) state.selected[r.id] = r;
        });
        renderTable();
        openModal();
        $root.find('.lom-new-owner').val(last.owner);
        updatePreview();
    }

    function exportCsv() {
        var blob = new Blob([core.toCsv(state.filtered, state.userSet)], { type: 'text/csv' });
        var a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = 'lookup_owners.csv';
        document.body.appendChild(a);
        a.click();
        setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 0);
    }

    // ---------- Events ----------

    var nameTimer;
    $root.on('input', '.lom-f-name', function () {
        clearTimeout(nameTimer);
        nameTimer = setTimeout(function () { readFilters(); state.page = 0; refresh(); }, 200);
    });
    $root.on('change', '.lom-f-apps, .lom-f-owners, .lom-f-sharing, .lom-f-orphan', function () {
        readFilters(); state.page = 0; refresh();
    });
    $root.on('click', '.lom-clear', function () {
        $root.find('.lom-f-name').val('');
        $root.find('.lom-f-apps option, .lom-f-owners option').prop('selected', false);
        $root.find('.lom-f-sharing, .lom-f-orphan').prop('checked', false);
        readFilters(); state.page = 0; refresh();
    });
    $root.on('click', 'th[data-key]', function () {
        var k = $(this).data('key');
        if (state.sortKey === k) state.sortDir = state.sortDir === 'asc' ? 'desc' : 'asc';
        else { state.sortKey = k; state.sortDir = 'asc'; }
        refresh();
    });
    $root.on('change', '.lom-row', function () {
        var id = $(this).closest('tr').attr('data-id');
        var row = state.filtered.find(function (r) { return r.id === id; });
        if (this.checked && row) state.selected[id] = row; else delete state.selected[id];
        renderTable();
    });
    $root.on('change', '.lom-select-page', function () {
        var start = state.page * state.pageSize;
        var on = this.checked;
        state.filtered.slice(start, start + state.pageSize).forEach(function (r) {
            if (on) state.selected[r.id] = r; else delete state.selected[r.id];
        });
        renderTable();
    });
    $root.on('change', '.lom-pagesize', function () { state.pageSize = +this.value; state.page = 0; refresh(); });
    $root.on('click', '.lom-prev', function () { state.page--; renderTable(); });
    $root.on('click', '.lom-next', function () { state.page++; renderTable(); });
    $root.on('click', '.lom-refresh', load);
    $root.on('click', '.lom-export', exportCsv);
    $root.on('click', '.lom-change', openModal);
    $root.on('click', '.lom-cancel', closeModal);
    $root.on('input change', '.lom-new-owner, .lom-confirm-count', updatePreview);
    $root.on('click', '.lom-confirm', execute);
    $root.on('click', '.lom-retry', retryFailed);
    $root.on('click', '.lom-dismiss', function () { $root.find('.lom-results').attr('hidden', true); });
    $(document).on('keydown', function (e) { if (e.key === 'Escape') closeModal(); });

    load();
});
