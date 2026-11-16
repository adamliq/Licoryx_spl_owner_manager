#!/usr/bin/env bash
# Build dist/<app>-<version>.{spl,tgz}, release/<app>-<version>.spl and the
# readable text copy release/<app>-<version>.txt.
# The packaging itself is in package.py (cross-platform, stdlib only).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPL=$(python3 "$ROOT/scripts/package.py" --out-dir "$ROOT/dist")
mkdir -p "$ROOT/release"
cp "$SPL" "$ROOT/release/$(basename "$SPL")"
python3 "$ROOT/scripts/make_text_bundle.py" >/dev/null   # release/<app>-<version>.txt
echo "${SPL%.spl}.tgz"
