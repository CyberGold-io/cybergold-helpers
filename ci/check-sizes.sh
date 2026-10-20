#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

SIZE_LIMIT=24576 # bytes; enforced per-contract limit for deployable artifacts.
PRODUCT_RUNTIME_MARGIN=4096
PRODUCT_SIZE_LIMIT=$((SIZE_LIMIT - PRODUCT_RUNTIME_MARGIN))

function check_sizes_enforce() {
  echo "Running size check (enforced; limit ${SIZE_LIMIT} bytes per contract) for $ROOT ..."
  local output
  set +e
  output="$(FOUNDRY_BYTECODE_SIZE_LIMIT=1000000 FOUNDRY_NO_BYTECODE_SIZE_CHECK=1 forge build \
    --root "$ROOT" "$ROOT/src" "$ROOT/script" --sizes 2>&1)"
  local status=$?
  set -e
  echo "$output"
  if [[ $status -ne 0 ]]; then
    return $status
  fi
  local exceed=0
  local deployable_count=0
  declare -A seen=()
  while IFS='|' read -r _ name runtime_size _rest; do
    name="${name#${name%%[![:space:]]*}}"
    name="${name%${name##*[![:space:]]}}"
    # Foundry appends source paths when profile artifacts share a contract name.
    name="${name%% (*}"
    runtime_size="${runtime_size//[[:space:],]/}"
    [[ -z "$name" || ! "$runtime_size" =~ ^[0-9]+$ ]] && continue
    deployable_count=$((deployable_count + 1))
    seen["$name"]=1
    if (( runtime_size > SIZE_LIMIT )); then
      echo "ERROR: $name size $runtime_size exceeds limit $SIZE_LIMIT bytes" >&2
      exceed=1
    fi
    case "$name" in
      RouterAdminFacet|RouterIssuePreviewFacet|RouterIssueFacet|RouterIssueBasketFacet|RouterRedeemFacet|RouterRedeemBasketFacet|RecoveryShareReceiverFacet)
        if (( runtime_size > PRODUCT_SIZE_LIMIT )); then
          echo "ERROR: $name size $runtime_size leaves less than ${PRODUCT_RUNTIME_MARGIN} bytes of EIP-170 margin" >&2
          exceed=1
        fi
        ;;
    esac
  done <<< "$output"

  if (( deployable_count == 0 )); then
    echo "ERROR: production size check parsed no deployable contracts" >&2
    return 1
  fi

  local required
  for required in HelpersDiamond DiamondInit RouterAdminFacet RouterIssuePreviewFacet RouterIssueFacet RouterIssueBasketFacet RouterRedeemFacet RouterRedeemBasketFacet RecoveryShareReceiverFacet; do
    if [[ -z "${seen[$required]:-}" ]]; then
      echo "ERROR: production size report omitted required deployable $required" >&2
      exceed=1
    fi
  done
  return $exceed
}

if ! check_sizes_enforce; then
  exit 1
fi
