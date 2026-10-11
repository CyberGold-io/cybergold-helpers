#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

status=0

echo "==> forge build"
if ! forge build --root "$ROOT"; then
  status=1
fi

echo "==> forge test (non-fork suites)"
if ! forge test --root "$ROOT" --no-match-path "test/*Fork*.t.sol"; then
  status=1
fi

exit $status
