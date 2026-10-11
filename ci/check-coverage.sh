#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

COVERAGE_DIR="${ROOT}/out/coverage"
COVERAGE_FILE="${COVERAGE_DIR}/helpers.lcov"
COVERAGE_LOG="${COVERAGE_DIR}/helpers.log"

mkdir -p "$COVERAGE_DIR"

echo "==> forge coverage (helpers source)"
# ZeroExAdapter is retained as dormant source only: it is deliberately absent from the
# launch deployer, release ABI, qualification suites, and coverage denominator. The
# deployed legacy coordinator and initializer remain frozen only for migration fixtures
# and reproducibility; future launch machinery exercises their live replacements.
if ! forge coverage \
  --root "$ROOT" \
  --quiet \
  --exclude-tests \
  --report lcov \
  --report-file "$COVERAGE_FILE" \
  --no-match-coverage "lib|script|test|src/adapters/ZeroExAdapter.sol|src/deploy/DiamondInit.sol" \
  --no-match-path "test/*Fork*.t.sol" >"$COVERAGE_LOG" 2>&1; then
  cat "$COVERAGE_LOG" >&2
  exit 1
fi

"$ROOT/lib/cybergold-protocol/ci/helpers/check-lcov-100.sh" \
  "$COVERAGE_FILE" "cybergold-helpers source" "^src/"
