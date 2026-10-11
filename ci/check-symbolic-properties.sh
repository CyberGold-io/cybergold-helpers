#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"
TOOLS="${SECURITY_TOOLS_DIR:-$ROOT/.security-tools}"
OUT="${SECURITY_ANALYSIS_OUT:-$ROOT/out/security-analysis}"
MODE="${SECURITY_ANALYSIS_MODE:-bounded}"
mkdir -p "$OUT"
[[ -x "$TOOLS/python/bin/halmos" ]] || { echo "ERROR: locked Halmos is missing" >&2; exit 1; }
case "$MODE" in
  bounded) timeout_assertion="20s"; width="64" ;;
  full) timeout_assertion="2m"; width="0" ;;
  *) echo "ERROR: SECURITY_ANALYSIS_MODE must be bounded or full" >&2; exit 1 ;;
esac
"$TOOLS/python/bin/halmos" --root "$ROOT" --contract AdapterRecoverySymbolicTest --function check --solver z3 \
  --solver-threads 1 --solver-timeout-assertion "$timeout_assertion" --width "$width" --loop 2 --statistics \
  --json-output "$OUT/halmos-helpers.json"
