#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

echo "==> forge build --ast"
forge build --root "$ROOT" --force --ast --skip test --skip script

echo "==> check NatSpec documentation"
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/lib/cybergold-protocol/ci/helpers/check_natspec.py" "$ROOT" src
