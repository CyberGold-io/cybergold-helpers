#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

workflow="$ROOT/.github/workflows/diamond-ci.yml"
if grep -Eq 'git config --global.*(x-access-token|SUBMODULE_TOKEN)' "$workflow"; then
  echo "ERROR: Helpers CI must not persist submodule credentials in global Git config" >&2
  exit 1
fi

if grep -Eq 'Skipping checks \(cybergold-protocol submodule unavailable|Skipping fork suites \(cybergold-protocol submodule unavailable' \
  "$ROOT/ci/ci-check.sh" "$ROOT/script/test.sh"; then
  echo "ERROR: Helpers checks must not succeed when the Protocol submodule is unavailable" >&2
  exit 1
fi

python3 "$ROOT/lib/cybergold-protocol/ci/check-workflow-pins.py" --project-root "$ROOT"
python3 "$ROOT/ci/check-workflow-policy.py"

echo "Helpers workflow uses immutable Actions, least privilege, and fail-closed checks."
