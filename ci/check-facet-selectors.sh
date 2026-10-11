#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

echo "==> Facet selector table sync"
"$ROOT/script/generate-facet-selectors.sh" --check
