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

A `power` user cannot change the owner even of their own lookup (tested on
Splunk Enterprise 10.6.1).

Changing the owner of a private (user-shared) lookup moves the file into the
new owner's private space: the previous owner loses access to it.

Private lookups that belong to a **deleted** user are not visible through the
REST API, so this app can't list them. To recover one, recreate the user with
the same name, reassign the lookup, then delete the user again.

## Audit

Every change is a REST call made as you, through Splunk Web. Splunk does not
write owner changes to `_audit`, but Splunk Web's access log records each one
with the acting user:

    index=_internal sourcetype=splunkd_ui_access "POST" "/lookup-table-files/" "/acl"
    | rex "^\S+ - (?<acting_user>\S+) \[[^\]]+\] \"POST (?<uri>\S+)[^\"]*\" (?<status>\d+)"
    | table _time acting_user uri status

Note that `_internal` has a short retention period and is not always searchable
by non-admins on Splunk Cloud.
