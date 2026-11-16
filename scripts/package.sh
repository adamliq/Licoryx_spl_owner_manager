#!/usr/bin/env bash
# Build dist/<app>-<version>.{spl,tgz} and release/<app>-<version>.spl.
# The packaging itself is in package.py (cross-platform, stdlib only).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPL=$(python3 "$ROOT/scripts/package.py" --out-dir "$ROOT/dist")
mkdir -p "$ROOT/release"
cp "$SPL" "$ROOT/release/$(basename "$SPL")"
echo "${SPL%.spl}.tgz"
