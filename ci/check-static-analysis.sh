#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

PROTOCOL="${CYBERGOLD_PROTOCOL_SECURITY_ROOT:-$ROOT/lib/cybergold-protocol}"
TOOLS="${SECURITY_TOOLS_DIR:-$ROOT/.security-tools}"
OUT="${SECURITY_ANALYSIS_OUT:-$ROOT/out/security-analysis}"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cybergold-helpers-static.XXXXXX")"
BUILD_OUT="$BUILD_ROOT/out"
BUILD_CACHE="$BUILD_ROOT/cache"
mkdir -p "$OUT" "$BUILD_OUT" "$BUILD_CACHE"

python3 "$PROTOCOL/ci/check-security-toolchain.py"
if [[ ! -x "$TOOLS/python/bin/slither" || ! -x "$TOOLS/aderyn" ]]; then
  echo "ERROR: locked security tools are missing; run lib/cybergold-protocol/ci/install-security-tools.sh \"$TOOLS\"" >&2
  exit 1
fi

# Stay offline by default after local tool bootstrap, while allowing a clean CI
# runner to opt into downloading the exact compiler pinned by foundry.toml.
FOUNDRY_OFFLINE="${FOUNDRY_OFFLINE:-true}" forge build --out "$BUILD_OUT" --cache-path "$BUILD_CACHE" --build-info --skip test script --force
# Crytic Compile reads compiler banks in mtime order. Parallel Foundry profiles can
# finish in either order, changing Slither's cross-bank observations for identical
# JSON. Order only these disposable files by their compiler content IDs; retain
# every bank and leave all compiler input/output bytes untouched.
python3 - "$BUILD_OUT/build-info" <<'PY'
import os
from pathlib import Path
import sys

for index, path in enumerate(sorted(Path(sys.argv[1]).glob("*.json"))):
    os.utime(path, (index, index))
PY
set +e
slither_tmp="$(mktemp -d "$OUT/slither.XXXXXX")"
slither_json="$slither_tmp/slither.json"
"$TOOLS/python/bin/slither" . --compile-force-framework foundry --ignore-compile \
  --foundry-out-directory "$BUILD_OUT" --exclude-dependencies --json "$slither_json" >"$OUT/slither.txt" 2>&1
slither_status=$?
set -e
if [[ "$slither_status" -ne 0 && "$slither_status" -ne 255 ]]; then
  cat "$OUT/slither.txt" >&2
  exit "$slither_status"
fi
mv -f "$slither_json" "$OUT/slither.json"

set +e
"$TOOLS/aderyn" . --src src --path-excludes lib,test,script --output "$OUT/aderyn.json" >"$OUT/aderyn.txt" 2>&1
aderyn_status=$?
set -e
if [[ "$aderyn_status" -ne 0 ]]; then
  if [[ "$(uname -s)" != "Darwin" || "$aderyn_status" -ne 101 ]] || ! python3 -m json.tool "$OUT/aderyn.json" >/dev/null; then
    cat "$OUT/aderyn.txt" >&2
    exit "$aderyn_status"
  fi
  echo "WARNING: Aderyn 0.6.8 completed its report before a known macOS network-store shutdown panic" >&2
fi

python3 "$PROTOCOL/ci/static-analysis-gate.py" --slither "$OUT/slither.json" --aderyn "$OUT/aderyn.json" \
  --baseline "$ROOT/ci/static-analysis-baseline.json" --tool-lock "$PROTOCOL/ci/security-tools.lock.json" \
  --scope-prefix src/ --out "$OUT/normalized.json" \
  --sarif-out "$OUT/static-analysis.sarif"
