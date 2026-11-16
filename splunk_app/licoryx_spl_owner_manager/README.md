# Lookup Owner Manager (POC)

Find CSV lookup table files and change their owner from a single page.

## How it works

The "Lookup Owners" page runs entirely in the browser. It calls Splunk's
REST API through Splunk Web using **your own session**. The app has no
server-side code, no stored credentials and no service account, so it can
never do more than your role allows.

REST endpoints used:

- `GET /services/authentication/current-context` (your username and capabilities)
- `GET /servicesNS/-/-/data/lookup-table-files` (the lookup list)
- `GET /services/authentication/users` (orphan detection; optional)
- `POST <lookup>/acl` with `owner`, the current `sharing`, and the current `perms.read` / `perms.write`

## Permissions

Changing another user's object normally needs the `admin_all_objects`
capability (`sc_admin` on Splunk Cloud, `admin` on Splunk Enterprise).
The "Can change owners" badge is only a hint; Splunk enforces the real check.

Private (user-shared) lookups are skipped by default, because the file sits in
the old owner's user folder. A checkbox in the confirmation dialog includes them
for testing.

## Audit

Every change is a REST call made as you. To review changes:

    index=_internal sourcetype=splunkd_access method=POST uri="*/data/lookup-table-files/*/acl"
    | table _time user uri status
