#!/usr/bin/env bash
set -euo pipefail

# Separate settlement qualification; preserve the historical symbolic gate.
# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../ci/helpers" && pwd)/bootstrap.sh"
TOOLS="${SECURITY_TOOLS_DIR:-$ROOT/.security-tools}"
OUT="${SECURITY_ANALYSIS_OUT:-$ROOT/out/market-security-qualification}"
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cybergold-helpers-market-symbolic.XXXXXX")"
trap 'rm -rf "$BUILD_ROOT"' EXIT
mkdir -p "$OUT"

FOUNDRY_TEST="$ROOT/test" FOUNDRY_OUT="$BUILD_ROOT/out" FOUNDRY_CACHE_PATH="$BUILD_ROOT/cache" \
  "$TOOLS/python/bin/halmos" --root "$ROOT" --forge-build-out "$BUILD_ROOT/out" \
    --contract MarketSwapSymbolicTest --function check --solver z3 \
    --solver-threads 1 --solver-timeout-assertion 2m --width 0 --loop 2 --statistics \
    --json-output "$OUT/halmos-market.json"
