#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

python3 "$ROOT/lib/cybergold-protocol/script/generate-release-abi.py" \
  --root "$ROOT" \
  --config script/config/helpers-release-abi.json \
  --check

python3 "$ROOT/ci/check-helpers-abi-semantics.py"

python3 "$ROOT/script/generate-market-abi.py" --check
