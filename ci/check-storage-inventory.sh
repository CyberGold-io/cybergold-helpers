#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

engine="$ROOT/lib/cybergold-protocol/ci/check-storage-inventory.py"
config="$ROOT/ci/storage-inventory.config.json"
inventory="$ROOT/ci/storage-inventory.json"

args=(
  --project-root "$ROOT"
  --config "$config"
  --inventory "$inventory"
)
if [[ "${1:-}" == "--update" ]]; then
  args+=(--update)
elif [[ -n "${1:-}" ]]; then
  echo "Usage: $0 [--update]" >&2
  exit 2
fi

# The inventory engine resolves declaration IDs across the complete closure.
# Analyze one fresh compiler job: default/IR jobs otherwise reuse numeric AST
# IDs for different declarations. This bank is analysis-only, never deployment
# output, and changes no production compiler setting or storage predicate.
scope_parent="${FOUNDRY_OUT:-$ROOT/out}/storage-inventory"
case "$scope_parent" in
  /*) ;;
  *) scope_parent="$ROOT/$scope_parent" ;;
esac
mkdir -p "$scope_parent"
inventory_bank="$(mktemp -d "$scope_parent/bank.XXXXXX")"
trap 'rm -rf "$inventory_bank"' EXIT
FOUNDRY_OUT="$inventory_bank/out" FOUNDRY_CACHE_PATH="$inventory_bank/cache" \
  FOUNDRY_ADDITIONAL_COMPILER_PROFILES='[]' FOUNDRY_COMPILATION_RESTRICTIONS='[]' \
  FOUNDRY_VIA_IR=true python3 "$engine" "${args[@]}"
