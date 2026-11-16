# Scope: Licoryx Lookup Owner Manager (Splunk app)

**Status:** Draft scope, 2026-11-16. POC v0.1.0 built (see README).
**App ID (proposed):** `licoryx_spl_owner_manager`

## 1. Goal

Give Splunk admins a UI to find lookup table files and change who owns them. The main use cases are:

- **Orphaned lookups.** The owner left, was disabled or was renamed, and the lookup still has to be maintained.
- **Hand-offs.** Moving ownership from one person to a service account or team owner.
- **Clean-up.** Finding lookups by app, owner, sharing level or name pattern, then reassigning many at once.

## 2. Requirements and how the design meets them

| # | Requirement | Design decision |
|---|---|---|
| R1 | Passes AppInspect | Ship no binaries, no Python, no `local/`, no `authorize.conf` and no stored credentials. CI runs `splunk-appinspect --included-tags cloud` and fails the build on any failure or error. |
| R2 | Runs on Splunk Cloud | Everything goes through Splunk Web's REST proxy (`/splunkd/__raw/...`), so the app never needs management port 8089. It has no custom REST handlers, modular inputs or search commands. It targets both Victoria and Classic experiences. |
| R3 | UI with filtering to find the object | A custom page with a filter bar, a sortable and paginated table, and multi-select (see §5). |
| R4 | Uses only the user's permissions | All calls run in the browser with the logged-in user's Splunk Web session and CSRF token. The app has no server-side code, no `passAuth`, no system token and no service account. If the user lacks a permission, Splunk returns 403 and the UI shows it. |

R4 combined with R2 drives the most important design choice: **the app is client-side only.** A backend would only be needed to raise privileges, and R4 rules that out.

## 3. In scope / out of scope

### In scope (v1.0)
- CSV lookup table files (`data/lookup-table-files`) in every app the user can see.
- Filters: name (substring or wildcard), app, owner, sharing (`user` / `app` / `global`), orphaned only, and modified date if the endpoint returns it (see O4).
- Single and bulk owner change, with a confirmation step and a result for each object.
- Keeping the existing sharing level and read/write permissions when the owner changes.
- Telling the user up front when they lack the capability to make changes (read-only mode).
- Exporting the filtered list to CSV from the browser.

### Candidate for v1.1
- Lookup **definitions** (`data/transforms/lookups`), and showing which definition points at which file.
- Changing sharing (for example private to app) in the same action.
- An "Assign all orphans of user X to Y" shortcut.

### Out of scope
- KV Store collections. They have a different ACL model and data lives in the KV Store.
- Editing lookup contents. Use the Lookup Editor app for that.
- Other knowledge objects (saved searches, dashboards and so on). The same pattern could cover them later.
- Any privilege elevation, scheduled or automated reassignment, or server-side jobs.

## 4. Architecture

```
Browser (logged-in user)
  └─ App page (Splunk UI Toolkit / React)
       ├─ GET  /splunkd/__raw/services/authentication/current-context   → capabilities, username
       ├─ GET  /splunkd/__raw/servicesNS/-/-/data/lookup-table-files     → list (count=0, output_mode=json)
       ├─ GET  /splunkd/__raw/services/authentication/users              → active users (orphan check, owner picker)
       ├─ GET  /splunkd/__raw/services/apps/local                        → app filter values
       └─ POST /splunkd/__raw/servicesNS/<owner>/<app>/data/lookup-table-files/<name>/acl
              body: owner=<new>&sharing=<current>&perms.read=<current>&perms.write=<current>
```

- **Session and CSRF:** use `@splunk/splunk-utils/fetch` (`defaultFetchInit`, `createRESTURL`). It adds the `X-Splunk-Form-Key` header from the session cookie.
- **Owner change:** POST to the object's `/acl` endpoint. `sharing` is required on every ACL POST. Always send back the current sharing and `perms.*` values so the change touches only the owner.
- **Bulk:** run requests one after another, or at most 3 at a time. Report success or the error for each object. Do not roll back on partial failure; show what changed instead.
- **Search head clusters (Cloud):** ACL changes made through REST replicate across the cluster, so no extra handling is needed. Re-fetch after writes so the table reflects the server's state.
- **Orphan detection:** an owner is orphaned if they are not in `authentication/users`, or if their account is locked or disabled where the field is available. `nobody` is treated as "no owner", not as orphaned. If the user cannot list users, hide the orphan filter and say why.

## 5. UI specification

**Page: "Lookup Owners"** (the default view in the app nav)

1. **Header:** shows the current user, a capability badge ("Can change owners" or "Read-only") and a refresh button.
2. **Filter bar:**
   - Name search (case-insensitive substring; `*` works as a wildcard)
   - App (multi-select)
   - Owner (multi-select, includes `nobody`)
   - Sharing (multi-select: private / app / global)
   - "Orphaned only" toggle
   - Clear-all button
   - Filters are kept in the URL query string so a view can be bookmarked or shared.
3. **Results table:** checkbox, Name, App, Owner (marked if orphaned), Sharing, Read perms, Write perms and file size if available. Columns are sortable and the table is paginated (25/50/100 rows). A row count is shown, such as "Showing 1–50 of 312".
4. **Action bar** (appears when rows are selected): **Change owner…** opens a modal with:
   - a type-ahead picker for the new owner (active users, plus `nobody`)
   - a preview table of the selected objects (current owner → new owner)
   - warnings for private (`user`-sharing) objects (see O1)
   - a Confirm button. Bulk changes ask the user to type the number of objects.
5. **Results panel:** success or failure for each object, with the Splunk error message, and a "Retry failed" button.
6. **Empty, error and loading states,** including a clear message on 403: "Your role lacks permission to change ownership of this object."

Filtering runs in the browser on the full list. That is enough for tens of thousands of lookups. If O5 shows otherwise, switch to server-side `search=` filtering.

## 6. Permissions model (R4)

- The app ships with **no** roles, capabilities or `authorize.conf`. That keeps Cloud vetting simple and makes clear the app grants nothing.
- Whether a change succeeds is decided only by Splunk, based on the user's own roles.
  - Reassigning another user's object is expected to need `admin_all_objects` (held by `sc_admin` on Cloud and `admin` on Enterprise). To be confirmed in the spike (O2).
- The UI reads `current-context` capabilities only to warn the user early. Splunk still enforces the permission; the UI check is not a security control.
- `metadata/default.meta`:
  - `[] access = read : [ * ], write : [ admin, sc_admin ]`, `export = none`
  - The view and nav can be limited to admin roles to reduce clutter. This is cosmetic.
- Auditing: Splunk already records each REST call, with the acting user, in `_internal` (`splunkd_access.log`) and in `_audit`. The README will include a sample audit search. The app does not write its own audit index in v1, because that would need write access the user might not have.

## 7. Splunk Cloud and AppInspect compliance checklist

- [ ] `default/app.conf`: `[id] name/version`, `[package] id`, `[launcher] author/description/version`, `[install] is_configured = 0`, `[ui] is_visible = 1`. No `build` collisions. Use semantic versioning.
- [ ] `app.manifest` (schema 2.0), `README.md`, `LICENSE`, and `static/appIcon*.png` in the required sizes.
- [ ] No `local/`, no `local.meta`, no `*.pyc`, no hidden files, no executables, no symlinks, and file permissions of 644/755.
- [ ] No inline `<script>`, no `eval`, no remote or CDN assets. All JavaScript is bundled into `appserver/static/`.
- [ ] No jQuery older than 3.5. The React UI uses no jQuery.
- [ ] No hard-coded hosts, ports or credentials. All URLs are relative, built with `createRESTURL`.
- [ ] No `authorize.conf`, `passwords.conf`, `server.conf` or `web.conf` changes.
- [ ] Packaged with `tar` and `COPYFILE_DISABLE=1` (or `slim package`). The top folder name equals the app ID.
- [ ] CI runs `splunk-appinspect inspect <pkg>.tgz --mode precert --included-tags cloud` and requires 0 failures and 0 errors. Warnings are reviewed one by one.
- [ ] Before release, submit the package to the AppInspect API with the `cloud` and `private_victoria` tags. Then either publish to Splunkbase or upload it as a private app through Cloud self-service install.

## 8. Proposed repository layout

```
licoryx_spl_owner_manager/
├─ packages/owner-manager-app/          # Splunk UI Toolkit monorepo package
│  ├─ src/main/webapp/pages/lookup_owners/   # React page entry
│  └─ stage/                            # build output = the Splunk app
├─ packages/lookup-owner-table/         # React components (filter bar, table, modal)
├─ splunk_app/licoryx_spl_owner_manager/ # static app skeleton (conf, meta, icons)
│  ├─ app.manifest
│  ├─ default/app.conf
│  ├─ default/data/ui/nav/default.xml
│  ├─ default/data/ui/views/lookup_owners.xml
│  ├─ appserver/static/                 # built JS bundle lands here
│  ├─ metadata/default.meta
│  └─ static/appIcon*.png
├─ scripts/package.sh                   # build → stage → tgz
├─ .github/workflows/ci.yml             # lint, unit test, build, AppInspect
└─ README.md
```

## 9. Open questions and risks (resolved in the Week-1 spike)

| ID | Question / risk | Plan |
|---|---|---|
| O1 | **Private (`sharing=user`) lookups.** The file lives under `etc/users/<old>/<app>/lookups/`. Changing only the owner may leave it in the old user's folder, where the new owner can't reach it. | Test on Cloud and Enterprise. Likely v1 behaviour: block owner change on private objects, or offer "share to app first" as an explicit two-step action with a warning. |
| O2 | Exact capability needed to change owner, and whether an object's owner can hand it off without `admin_all_objects`. | Test with `sc_admin`, `power` and a custom role. Write the results into the README. |
| O3 | **UI framework passes Cloud vetting.** The UI Toolkit page (`type="html"` view with a template) needs to pass the current AppInspect `cloud` tag checks. | First task in the spike: build a hello-world page, package it and run AppInspect. Fallback: a Simple XML `version="1.1"` dashboard with a bundled JS extension, still client-side only. |
| O4 | Fields returned by `lookup-table-files` (size and modified time are not always present). | Check; drop those columns if they are missing. |
| O5 | Performance with very large estates (more than 20k lookups) and many apps. | Use `count=0` with `f=` field filtering to shrink the payload. If needed, fall back to server-side `search=` filtering. |
| O6 | Lookups whose definitions (transforms) are owned by a different user. | Show a hint in v1. Handle fully in v1.1. |
| O7 | Non-admin users without `list_users` / `edit_user` can't fetch the user list. | Degrade gracefully: free-text owner input and no orphan filter. |

## 10. Milestones (estimate: 1 developer)

| Phase | Work | Est. |
|---|---|---|
| 0. Spike | Settle O1–O3 on a Cloud dev stack and a local Enterprise Docker. Hello-world app passes AppInspect `cloud`. | 2–3 d |
| 1. Skeleton and CI | Repo layout, UI Toolkit setup, app.conf/meta/manifest, package script, GitHub Actions with AppInspect | 2 d |
| 2. List and filter | Data fetching, filters, table, URL state, CSV export | 3–4 d |
| 3. Change owner | Modal, single and bulk ACL POST, results panel, retry, capability badge | 3 d |
| 4. Hardening | Error states, accessibility, light and dark themes, unit tests (Jest/RTL), docs | 2–3 d |
| 5. Validation | Test matrix (§11), AppInspect API cloud vetting, private-app install on Cloud | 2 d |
| **Total** | | **~14–17 d** |

## 11. Acceptance criteria and test matrix

**Acceptance criteria**
- The AppInspect CLI and API report 0 failures and 0 errors with the `cloud` tags.
- The app installs as a private app on Splunk Cloud (Victoria) and works without support tickets or configuration.
- An `sc_admin` user can filter to the orphaned lookups in app X and reassign 50 of them in one action. Sharing and permissions are unchanged afterwards (checked with `| rest`).
- A `user`-role account can open the app, sees "Read-only" and only the lookups it can access, and any change attempt returns Splunk's 403 shown clearly.
- No network call from the page goes anywhere except relative Splunk Web paths (checked in the browser dev tools).
- Every change shows up in `_internal` / `_audit` attributed to the acting user.

**Test matrix**

| Platform | Roles | Sharing | Scenarios |
|---|---|---|---|
| Cloud (Victoria) and Enterprise 9.x/10.x (Docker) | sc_admin or admin, power, user, custom | private, app, global | single and bulk change, partial failure, orphan, `nobody` owner, search head cluster replication, 403 path, more than 10k lookups |
