#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"
# shellcheck source=/dev/null
source "$ROOT/script/helpers/config.sh"

admin="$(config_read "helpers.admin")"
if [[ "${admin,,}" != "0x0000000000000000000000000000000000000000" ]]; then
  echo "ERROR: config/deploy-config.json must not contain a default Helpers owner" >&2
  exit 1
fi

echo "Helpers deploy config owner default is safely disabled."
