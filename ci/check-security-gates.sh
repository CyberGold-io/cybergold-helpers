#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> High-severity authored-source Solidity lint"
python3 lib/cybergold-protocol/ci/check-high-severity-lints.py \
  --project-root "$ROOT" src script

GITLEAKS_BIN="${GITLEAKS_BIN:-$(command -v gitleaks || true)}"
if [[ -z "$GITLEAKS_BIN" || ! -x "$GITLEAKS_BIN" ]]; then
  echo "ERROR: pinned Gitleaks is required; run the Protocol submodule's ci/install-gitleaks.sh or set GITLEAKS_BIN" >&2
  exit 1
fi
echo "==> Full-history secret regression scan"
"$GITLEAKS_BIN" git . --redact --no-banner --baseline-path ci/gitleaks-baseline.json
