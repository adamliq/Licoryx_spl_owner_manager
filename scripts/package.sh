#!/usr/bin/env bash
# Build dist/<app>-<version>.tgz and release/<app>-<version>.spl with AppInspect-friendly permissions.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP=licoryx_spl_owner_manager
VERSION=$(sed -n 's/^version *= *//p' "$ROOT/splunk_app/$APP/default/app.conf" | head -1)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$ROOT/splunk_app/$APP" "$STAGE/$APP"
rm -rf "$STAGE/$APP/local" "$STAGE/$APP/metadata/local.meta"
find "$STAGE/$APP" -name '.*' -prune -exec rm -rf {} +
find "$STAGE/$APP" -type d -exec chmod 755 {} +
find "$STAGE/$APP" -type f -exec chmod 644 {} +
mkdir -p "$ROOT/dist"
OUT="$ROOT/dist/$APP-$VERSION.tgz"
COPYFILE_DISABLE=1 tar -C "$STAGE" --owner=0 --group=0 -czf "$OUT" "$APP"
# .spl is the Splunk app package extension; same gzipped tar format.
mkdir -p "$ROOT/release"
cp "$OUT" "$ROOT/release/$APP-$VERSION.spl"
echo "$OUT"
