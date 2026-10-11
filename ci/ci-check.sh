#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

CHECK_SUBMODULE_SCRIPT="$ROOT/ci/check-submodule-updated.sh"
CHECK_SELECTOR_SNAPSHOT_SCRIPT="$ROOT/ci/check-selector-snapshots.sh"
CHECK_SELECTOR_DUPLICATES_SCRIPT="$ROOT/ci/check-selector-duplicates.sh"
CHECK_SELECTOR_DUPLICATES_FAILURES_SCRIPT="$ROOT/ci/check-selector-duplicates-failures.sh"
CHECK_FORK_TESTS_SCRIPT="$ROOT/ci/check-fork-tests.sh"
CHECK_FORK_EVIDENCE_POLICY_SCRIPT="$ROOT/ci/check-fork-evidence-policy.py"
CHECK_TOOLCHAIN_SCRIPT="$ROOT/lib/cybergold-protocol/ci/check-toolchain.sh"
CHECK_BUILD_POLICY_SCRIPT="$ROOT/ci/check-build-policy.py"
CHECK_SOLIDITY_VERSION_SCRIPT="$ROOT/lib/cybergold-protocol/ci/check-solidity-version.sh"
CHECK_SOLIDITY_KNOWN_BUGS_SCRIPT="$ROOT/lib/cybergold-protocol/ci/check-solidity-known-bugs.py"
CHECK_FORMAT_SCRIPT="$ROOT/lib/cybergold-protocol/ci/check-format.sh"
CHECK_GAS_BUDGET_SCRIPT="$ROOT/ci/check-gas-budgets.sh"
CHECK_DEPLOY_CONFIG_SCRIPT="$ROOT/ci/check-deploy-config.sh"
CHECK_LATEST_ROUTERS_SCRIPT="$ROOT/ci/check-latest-router-releases.py"
CHECK_WORKFLOW_CREDENTIALS_SCRIPT="$ROOT/ci/check-workflow-credentials.sh"
CHECK_SECURITY_GATES_SCRIPT="$ROOT/ci/check-security-gates.sh"
CHECK_DORMANT_ZEROEX_SCRIPT="$ROOT/ci/check-dormant-zeroex.py"
CHECK_DOCS_SCRIPT="$ROOT/lib/cybergold-protocol/ci/check-docs.py"
CHECK_TERMINOLOGY_SCRIPT="$ROOT/lib/cybergold-protocol/ci/check-terminology.py"
CHECK_SECURITY_TOOLCHAIN_SCRIPT="$ROOT/lib/cybergold-protocol/ci/check-security-toolchain.py"
CHECK_HEAVY_GATES_SCRIPT="$ROOT/ci/check-heavy-gates.py"

case "${1:-}" in
  --update)
    "$CHECK_SELECTOR_SNAPSHOT_SCRIPT" --update
    ;;
  *)
    if [ -n "${SKIP_SUBMODULE_CHECK:-}" ]; then
      echo "==> Skipping exact submodule pin check by explicit request"
    else
      "$CHECK_SUBMODULE_SCRIPT"
    fi
    "$CHECK_SOLIDITY_VERSION_SCRIPT"
    python3 "$CHECK_SOLIDITY_KNOWN_BUGS_SCRIPT" --project-root "$ROOT"
    "$CHECK_TOOLCHAIN_SCRIPT"
    python3 "$CHECK_BUILD_POLICY_SCRIPT"
    python3 "$CHECK_SECURITY_TOOLCHAIN_SCRIPT"
    "$CHECK_FORMAT_SCRIPT"
    "$CHECK_GAS_BUDGET_SCRIPT"
    "$CHECK_DEPLOY_CONFIG_SCRIPT"
    python3 "$CHECK_LATEST_ROUTERS_SCRIPT"
    "$CHECK_WORKFLOW_CREDENTIALS_SCRIPT"
    python3 "$CHECK_DORMANT_ZEROEX_SCRIPT"
    "$CHECK_SECURITY_GATES_SCRIPT"
    python3 "$CHECK_DOCS_SCRIPT" "$ROOT"
    python3 "$CHECK_TERMINOLOGY_SCRIPT" --project-root "$ROOT"
    bash "$CHECK_SELECTOR_DUPLICATES_FAILURES_SCRIPT"
    "$CHECK_SELECTOR_DUPLICATES_SCRIPT"
    python3 "$CHECK_HEAVY_GATES_SCRIPT"
    python3 "$CHECK_FORK_EVIDENCE_POLICY_SCRIPT"
    bash "$CHECK_FORK_TESTS_SCRIPT"
    ;;
esac
