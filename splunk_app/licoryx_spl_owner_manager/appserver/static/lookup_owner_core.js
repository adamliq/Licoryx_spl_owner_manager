/*
 * Pure logic for the Lookup Owner Manager: no DOM, no network.
 * UMD wrapper so it loads as an AMD module in Splunk Web and as a
 * CommonJS module in Node for unit tests.
 */
(function (root, factory) {
    if (typeof define === 'function' && define.amd) {
        define([], factory);
    } else if (typeof module === 'object' && module.exports) {
        module.exports = factory();
    } else {
        root.LookupOwnerCore = factory();
    }
})(this, function () {
    'use strict';

    var NOBODY = 'nobody';

    /** Turn a lookup-table-files JSON response into flat rows. */
    function parseLookups(json) {
        var entries = (json && json.entry) || [];
        return entries.map(function (e) {
            var acl = e.acl || {};
            var perms = acl.perms || {};
            return {
                id: (e.links && e.links.alternate) || e.id || e.name,
                name: e.name,
                app: acl.app || '',
                owner: acl.owner || '',
                sharing: acl.sharing || '',
                readPerms: perms.read || [],
                writePerms: perms.write || [],
                canChangePerms: acl.can_change_perms !== false,
                aclPath: aclPathFor(e),
                path: (e.content && e.content['eai:data']) || '',
                updated: e.updated || ''
            };
        });
    }

    /**
     * ACL endpoint for an entry. Splunk 10.x does not list `acl` in
     * entry.links for lookup-table-files, but <alternate>/acl works.
     */
    function aclPathFor(e) {
        var links = e.links || {};
        if (links.acl) return links.acl;
        if (links.alternate) return links.alternate.replace(/\/$/, '') + '/acl';
        return null;
    }

    /** Names of users from an authentication/users response. */
    function parseUsers(json) {
        var entries = (json && json.entry) || [];
        return entries.map(function (e) { return e.name; }).sort();
    }

    function isOrphan(row, userSet) {
        if (!userSet) return false; // unknown: user list not readable
        if (!row.owner || row.owner === NOBODY) return false;
        return !userSet.has(row.owner);
    }

    /** "*" = any characters; otherwise case-insensitive substring. */
    function makeNameMatcher(pattern) {
        var p = (pattern || '').trim();
        if (!p) return function () { return true; };
        if (p.indexOf('*') === -1) {
            var lower = p.toLowerCase();
            return function (name) { return name.toLowerCase().indexOf(lower) !== -1; };
        }
        var re = new RegExp('^' + p.split('*').map(escapeRegex).join('.*') + '$', 'i');
        return function (name) { return re.test(name); };
    }

    function escapeRegex(s) {
        return s.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
    }

    /**
     * filters: { name, apps: [], owners: [], sharing: [], orphanOnly }
     * Empty arrays mean "no filter".
     */
    function applyFilters(rows, filters, userSet) {
        var f = filters || {};
        var nameOk = makeNameMatcher(f.name);
        var inList = function (list, v) { return !list || list.length === 0 || list.indexOf(v) !== -1; };
        return rows.filter(function (r) {
            return nameOk(r.name) &&
                inList(f.apps, r.app) &&
                inList(f.owners, r.owner) &&
                inList(f.sharing, r.sharing) &&
                (!f.orphanOnly || isOrphan(r, userSet));
        });
    }

    function sortRows(rows, key, dir) {
        var mul = dir === 'desc' ? -1 : 1;
        return rows.slice().sort(function (a, b) {
            var x = String(a[key] || '').toLowerCase();
            var y = String(b[key] || '').toLowerCase();
            return x < y ? -mul : x > y ? mul : 0;
        });
    }

    /**
     * Body for POST .../acl. Splunk requires `sharing` on every ACL POST.
     * Current perms are re-sent so only the owner changes.
     */
    function buildAclBody(row, newOwner) {
        var body = { owner: newOwner, sharing: row.sharing };
        if (row.sharing !== 'user') {
            if (row.readPerms.length) body['perms.read'] = row.readPerms.join(',');
            if (row.writePerms.length) body['perms.write'] = row.writePerms.join(',');
        }
        return body;
    }

    /**
     * Why a row can't be changed, or null if it can.
     * Private (sharing=user) lookups are allowed: on Splunk 10.6 an owner
     * change moves the file into the new owner's user folder.
     */
    function blockReason(row, newOwner) {
        if (!row.aclPath) return 'No ACL endpoint returned for this object.';
        if (!newOwner) return 'No new owner selected.';
        if (row.owner === newOwner) return 'Already owned by ' + newOwner + '.';
        return null;
    }

    function hasCapability(caps, name) {
        return Array.isArray(caps) && caps.indexOf(name) !== -1;
    }

    /** Pull a readable message out of a splunkd error. */
    function errorMessage(err) {
        if (!err) return 'Unknown error';
        var msgs = err.data && err.data.messages;
        if (msgs && msgs.length && msgs[0].text) return msgs[0].text;
        if (err.status === 403) return 'Forbidden: your role lacks permission for this object.';
        if (err.status) return 'HTTP ' + err.status;
        return String(err.message || err);
    }

    function csvCell(v) {
        var s = Array.isArray(v) ? v.join(';') : String(v == null ? '' : v);
        // Neutralise spreadsheet formula injection.
        if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;
        return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
    }

    function toCsv(rows, userSet) {
        var header = ['name', 'app', 'owner', 'sharing', 'orphaned', 'perms_read', 'perms_write'];
        var lines = [header.join(',')];
        rows.forEach(function (r) {
            lines.push([r.name, r.app, r.owner, r.sharing, isOrphan(r, userSet),
                r.readPerms, r.writePerms].map(csvCell).join(','));
        });
        return lines.join('\r\n') + '\r\n';
    }

    /**
     * Run async tasks with limited concurrency.
     * worker(item, done) where done(result). Calls onEach(result, index), then onAll(results).
     */
    function runLimited(items, limit, worker, onEach, onAll) {
        var results = new Array(items.length);
        var next = 0, finished = 0;
        if (items.length === 0) { onAll(results); return; }
        function launch() {
            if (next >= items.length) return;
            var i = next++;
            worker(items[i], function (res) {
                results[i] = res;
                if (onEach) onEach(res, i);
                finished++;
                if (finished === items.length) onAll(results);
                else launch();
            });
        }
        for (var k = 0; k < Math.min(limit, items.length); k++) launch();
    }

    function escapeHtml(s) {
        return String(s == null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }

    return {
        NOBODY: NOBODY,
        parseLookups: parseLookups,
        parseUsers: parseUsers,
        isOrphan: isOrphan,
        makeNameMatcher: makeNameMatcher,
        applyFilters: applyFilters,
        sortRows: sortRows,
        buildAclBody: buildAclBody,
        blockReason: blockReason,
        hasCapability: hasCapability,
        errorMessage: errorMessage,
        toCsv: toCsv,
        runLimited: runLimited,
        escapeHtml: escapeHtml
    };
});
