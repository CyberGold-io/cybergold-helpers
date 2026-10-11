#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

run_injected_failure() {
  local mode="$1"
  local expected
  local output
  if [[ "$mode" == "nonzero" ]]; then
    expected="ERROR: forge inspect failed for selector target"
  else
    expected="ERROR: selector target returned an empty method inventory"
  fi
  if output="$(SELECTOR_FAILURE_MODE="$mode" bash -c '
    forge() {
      if [[ "$SELECTOR_FAILURE_MODE" == "nonzero" ]]; then
        echo "injected forge inspect failure" >&2
        return 97
      fi
      return 0
    }
    export -f forge
    exec bash "$1"
  ' _ "$ROOT/ci/check-selector-duplicates.sh" 2>&1)"; then
    echo "ERROR: selector duplicate gate accepted injected forge mode: $mode" >&2
    return 1
  fi
  if [[ "$output" != *"$expected"* || "$output" != *"ERROR: selector gathering failed"* ]]; then
    echo "ERROR: selector duplicate gate failed for an unexpected reason in mode: $mode" >&2
    printf '%s\n' "$output" >&2
    return 1
  fi
}

run_injected_failure nonzero
run_injected_failure empty
echo "Selector duplicate gate rejected injected forge failure and empty inventory."
