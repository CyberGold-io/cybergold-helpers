#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

COVERAGE_DIR="${FOUNDRY_OUT:-${ROOT}/out}/coverage"
COVERAGE_FILE="${COVERAGE_DIR}/helpers.lcov"
mkdir -p "$COVERAGE_DIR"

# Foundry's multi-profile coverage mixes source IDs. Collect each compiler bank
# independently, then union real source-position counters. The shared conversion
# module also runs with default compilation so IR's orphaned branch anchors do
# not erase genuine default-profile observations of the same authored code.
# ZeroEx and the obsolete initializer retain their existing dormant exclusions.

echo "==> forge coverage (default compiler bank)"
if ! env FOUNDRY_OUT="$COVERAGE_DIR/default/out" \
  FOUNDRY_CACHE_PATH="$COVERAGE_DIR/default/cache" \
  FOUNDRY_ADDITIONAL_COMPILER_PROFILES='[]' FOUNDRY_COMPILATION_RESTRICTIONS='[]' \
  FOUNDRY_SKIP='["TradeExactInFacet.sol","TradeExactInputDeployment.sol","TradeExactInFacet.t.sol","TradeExactInputDeployment.t.sol"]' \
  forge coverage --root "$ROOT" --exclude-tests --report lcov \
  --report-file "$COVERAGE_DIR/default.lcov" \
  --no-match-coverage "(^|/)lib/|^script/|^test/|src/adapters/ZeroExAdapter.sol|src/deploy/DiamondInit.sol" \
  --no-match-path "test/*Fork*.t.sol" \
  >"$COVERAGE_DIR/default.log" 2>&1; then
  cat "$COVERAGE_DIR/default.log" >&2
  exit 1
fi

echo "==> forge coverage (exact-input IR compiler bank)"
if ! env FOUNDRY_OUT="$COVERAGE_DIR/exact-input/out" \
  FOUNDRY_CACHE_PATH="$COVERAGE_DIR/exact-input/cache" \
  FOUNDRY_SRC=src/facets FOUNDRY_TEST=test/exact-input FOUNDRY_SCRIPT=test/exact-input \
  FOUNDRY_ADDITIONAL_COMPILER_PROFILES='[]' FOUNDRY_COMPILATION_RESTRICTIONS='[]' \
  forge coverage --root "$ROOT" --ir-minimum --exclude-tests --report lcov \
  --report-file "$COVERAGE_DIR/exact-input.lcov" \
  --no-match-coverage '(^|/)lib/|^script/|^test/' \
  >"$COVERAGE_DIR/exact-input.log" 2>&1; then
  cat "$COVERAGE_DIR/exact-input.log" >&2
  exit 1
fi

python3 "$ROOT/ci/test-coverage-merge.py"
python3 "$ROOT/ci/merge-helpers-coverage.py" "$COVERAGE_FILE" \
  "$COVERAGE_DIR/default.lcov" "$COVERAGE_DIR/exact-input.lcov"
"$ROOT/lib/cybergold-protocol/ci/helpers/check-lcov-100.sh" \
  "$COVERAGE_FILE" "cybergold-helpers source" "^src/"
