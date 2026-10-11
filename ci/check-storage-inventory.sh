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

python3 "$engine" "${args[@]}"
