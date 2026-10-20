#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

forge build --root "$ROOT" --ast --skip test --skip script

python3 "$ROOT/script/generate-release-abi.py" --check

python3 "$ROOT/ci/check-helpers-abi-semantics.py"

python3 "$ROOT/script/generate-market-abi.py" --check
python3 "$ROOT/script/generate-exact-input-abi.py" --check
