#!/usr/bin/env bash
# Full end-to-end test against a local splunk/splunk docker container.
# Needs: docker, node, and Playwright (require('playwright') must resolve).
# Usage: tests/docker/run_all.sh [image]   (default splunk/splunk:latest)
set -euo pipefail
cd "$(dirname "$0")/../.."
IMAGE=${1:-splunk/splunk:latest}
PW='Chang3d!Passw0rd'; UPW='Us3rPassw0rd!'; API=https://localhost:8089
OUT=test-results; rm -rf "$OUT"; mkdir -p "$OUT"
PKG=$(scripts/package.sh)

docker rm -f splunk >/dev/null 2>&1 || true
docker run -d --name splunk --network host \
  -e SPLUNK_START_ARGS=--accept-license -e SPLUNK_GENERAL_TERMS=--accept-sgt-current-at-splunk-com \
  -e SPLUNK_PASSWORD="$PW" -e SPLUNK_APPS_URL=/tmp/app.tgz \
  -v "$PWD/$PKG:/tmp/app.tgz:ro" "$IMAGE" >/dev/null
echo "waiting for splunk..."
until [ "$(docker inspect -f '{{.State.Health.Status}}' splunk)" = healthy ]; do sleep 10; done

tests/docker/setup_data.sh splunk "$PW"

fail=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: expected '$3' got '$2'"; fail=1; fi; }
acl() { curl -sk -u "admin:$PW" "$API/servicesNS/-/-/data/lookup-table-files?output_mode=json&count=0&search=$1" |
  python3 -c "import json,sys; e=json.load(sys.stdin)['entry'][0]; a=e['acl']; print(a['owner'], a['sharing'], ','.join(a['perms']['read']) if a['perms'] else '-', ','.join(a['perms']['write']) if a['perms'] else '-')"; }
canread() { curl -sk -u "$1:$UPW" "$API/servicesNS/$1/search/search/jobs/export" -d search="| inputlookup $2 | stats count" -d output_mode=csv | tail -1; }

node tests/docker/e2e.js admin "$PW" bulk-orphans "$OUT" > "$OUT/admin-bulk.log" 2>&1
check "orphans reassigned, sharing/perms kept" "$(acl leaver_assets_1.csv)" "carol app * admin,power"
check "global orphan reassigned"               "$(acl leaver_global.csv)"   "carol global * admin,power"
check "new owner can read lookup"              "$(canread carol leaver_assets_1.csv)" "2"

node tests/docker/e2e.js admin "$PW" private "$OUT" > "$OUT/admin-private.log" 2>&1
check "private lookup reassigned"              "$(acl bob_private.csv)" "carol user - -"
check "private lookup readable by new owner"   "$(canread carol bob_private.csv)" "2"

node tests/docker/e2e.js bob "$UPW" non-owner "$OUT" > "$OUT/bob-nonowner.log" 2>&1
check "power user cannot change owner"         "$(acl bob_app.csv)" "bob app * admin,power"
check "403 shown in UI"                        "$(grep -c 'do not have permission' "$OUT/bob-nonowner.log")" "1"

node tests/docker/e2e.js alice "$UPW" view "$OUT" > "$OUT/alice-view.log" 2>&1
check "user role sees read-only badge"         "$(grep -c 'Read-only' "$OUT/alice-view.log")" "1"
check "no false orphans for non-admin"         "$(grep -c 'orphaned' "$OUT/alice-view.log")" "0"

check "no page errors"                         "$(cat "$OUT"/*.log | grep -c 'pageerror\|DIALOG')" "0"
sleep 15
check "changes audited as acting user" "$(curl -sk -u "admin:$PW" "$API/services/search/jobs/export" -d output_mode=csv \
  -d search='search index=_internal sourcetype=splunkd_access method=POST uri="*/bob_private.csv/acl" user=admin status=200 | stats count' | tail -1)" "1"

exit $fail
