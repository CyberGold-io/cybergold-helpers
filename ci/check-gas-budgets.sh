#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

snapshot_path="$ROOT/.gas-snapshot"
budget_path="$ROOT/ci/gas-budgets.json"
current_snapshot="$(mktemp "${TMPDIR:-/tmp}/helpers-gas-snapshot.XXXXXX")"
isolation_root="$(mktemp -d "${TMPDIR:-/tmp}/helpers-gas-foundry.XXXXXX")"
trap 'rm -f "$current_snapshot"; rm -rf "$isolation_root"' EXIT
mkdir -p "$isolation_root/out" "$isolation_root/cache"

route_pattern='test(TokenAllowanceIssueRefundsDustAndEmitsOneGenericOutcome|TokenIssueSupportsPermit2|ExactInUsesSignedBudgetsButPullsAndApprovesOnlyFreshExactLots|MixedRedemptionAggregatesErc20AndForwardsPositiveShares|Permit2AuthorizationWorksForCygld|DirectBasketExactInDeliversCompleteMixedVectorAndEmitsOnce|AdapterSetterBindsCurrentStateAndRejectsNoop|GenericMixedPreviewAndExecutionAtCoreMaxCombinedCardinality)'

FOUNDRY_OUT="$isolation_root/out" FOUNDRY_CACHE_PATH="$isolation_root/cache" forge snapshot \
  --root "$ROOT" \
  --no-match-path 'test/*Fork*.t.sol' \
  --match-test "$route_pattern" \
  --snap "$current_snapshot"

args=(
  --current "$current_snapshot"
  --baseline "$snapshot_path"
  --budgets "$budget_path"
)
if [ "${1:-}" = "--update" ]; then
  args+=(--update)
elif [ -n "${1:-}" ]; then
  echo "Usage: $0 [--update]" >&2
  exit 2
fi

python3 "$ROOT/ci/check-gas-budgets.py" "${args[@]}"
