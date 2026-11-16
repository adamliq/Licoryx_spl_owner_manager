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
scripts/package.sh                  # -> release/licoryx_spl_owner_manager-0.1.0.spl (+ dist/*.tgz)
splunk-appinspect inspect dist/*.tgz --mode precert --included-tags cloud
```

### End-to-end test against Splunk in Docker

```bash
tests/docker/run_all.sh            # starts splunk/splunk:latest, seeds users/lookups, runs UI tests
```

Results and screenshots land in `test-results/`.

## The app as a single text file

[`release/licoryx_spl_owner_manager-0.1.0.txt`](release/licoryx_spl_owner_manager-0.1.0.txt)
holds the whole app as plain, readable text: a short Python program followed by
every source file, each line prefixed with `#|`. Nothing is encoded. To rebuild
the app folder and the `.spl` from it (Python 3 only):

```bash
python licoryx_spl_owner_manager-0.1.0.txt --out-dir .     # Windows: py ...
```

The app icons are the only binary files, so the program draws them instead of
embedding them. The file still works if it was saved with Windows (CRLF) line
endings. `scripts/make_text_bundle.py` regenerates it, and `scripts/package.sh`
runs that automatically.

## Build the package yourself

If your network blocks downloading `.spl` / `.gz` files, build the package
locally from the plain source files instead. Python 3 is the only requirement
(Windows, macOS or Linux):

```bash
git clone https://github.com/adamliq/Licoryx_spl_owner_manager.git
cd Licoryx_spl_owner_manager
git checkout claude/wizardly-johnson-mkg4c9
python scripts/package.py          # Windows: py scripts\package.py
```

This writes `dist/licoryx_spl_owner_manager-0.1.0.spl` (and an identical
`.tgz`). It sets the file modes and ownership AppInspect expects, and leaves
out hidden files, `local/` and `local.meta`.

## Install

The ready-to-install package is
[`release/licoryx_spl_owner_manager-0.1.0.spl`](release/licoryx_spl_owner_manager-0.1.0.spl).
It is rebuilt by `scripts/package.sh` (which calls `scripts/package.py`) and passes AppInspect with the `cloud`
and `private_victoria` tags.

- **Splunk Enterprise:** Apps → Manage Apps → Install app from file, or
  `splunk install app licoryx_spl_owner_manager-0.1.0.spl`
- **Splunk Cloud:** Apps → Manage Apps → Upload App (private app; it goes
  through Cloud vetting automatically)

Then open **Lookup Owner Manager**.
