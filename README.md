# Licoryx_spl_owner_manager

A Splunk app for finding lookup table files and changing their owner. It works
only with the logged-in user's own permissions. See [SCOPE.md](SCOPE.md) for
the full scope.

## Proof of concept (v0.1.0)

- App source: `splunk_app/licoryx_spl_owner_manager/`
- The UI is a Simple XML (`version="1.1"`) dashboard with a bundled JS
  extension. There is no build step and no server-side code (the SCOPE O3
  fallback, chosen for speed).
- The logic is in `appserver/static/lookup_owner_core.js` and is unit-tested
  with Node.

```bash
node --test tests/core.test.js      # unit tests
scripts/package.sh                  # -> dist/licoryx_spl_owner_manager-0.1.0.tgz
splunk-appinspect inspect dist/*.tgz --mode precert --included-tags cloud
```

### End-to-end test against Splunk in Docker

```bash
tests/docker/run_all.sh            # starts splunk/splunk:latest, seeds users/lookups, runs UI tests
```

Results and screenshots land in `test-results/`.

Install the package on Splunk Enterprise (Apps → Install app from file) or
upload it to Splunk Cloud as a private app, then open **Lookup Owner Manager**.
