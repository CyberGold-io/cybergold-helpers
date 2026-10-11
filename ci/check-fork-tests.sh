#!/usr/bin/env bash
set +x
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

PINNED_MAINNET_FORK_BLOCK="25609006"
EXPECTED_FORK_SUITES=(
  "test/BasketRouterFork.t.sol:BasketRouterForkTest"
  "test/BasketRouterUniswapFork.t.sol:BasketRouterUniswapForkTest"
  "test/OneInchFork.t.sol:OneInchForkTest"
  "test/UniswapUniversalFork.t.sol:UniswapUniversalForkTest"
)
EXPECTED_FORK_TEST_COUNTS=(1 2 2 4)
EXPECTED_FORK_TEST_TOTAL=9
mode="development"

case "${1:-}" in
  "")
    ;;
  --release-evidence)
    mode="release-evidence"
    ;;
  *)
    echo "Usage: $0 [--release-evidence]" >&2
    exit 2
    ;;
esac

release_fork_mode="${HELPERS_RELEASE_FORK_MODE:-pinned-history}"
fork_block="${MAINNET_FORK_BLOCK:-$PINNED_MAINNET_FORK_BLOCK}"
fork_block_hash=""
if [[ "$mode" == "release-evidence" && "$release_fork_mode" == "live-latest-snapshot" ]]; then
  fork_block=""
else
  export MAINNET_FORK_BLOCK="$fork_block"
fi

evidence_dir="${HELPERS_FORK_EVIDENCE_OUT:-$ROOT/out/release-evidence/helpers-fork}"
source_commit=""
release_log=""
snapshot_result=""
post_identity=""
raw_log=""

cleanup() {
  if [[ -n "$raw_log" ]]; then
    rm -f "$raw_log"
  fi
  if [[ -n "$snapshot_result" ]]; then
    rm -f "$snapshot_result"
  fi
  if [[ -n "$post_identity" ]]; then
    rm -f "$post_identity"
  fi
}
trap cleanup EXIT

write_release_evidence() {
  local status="$1"
  local forge_exit_code="$2"
  local reason="$3"
  local log_path="${4:-}"

  mkdir -p "$evidence_dir"
  python3 - "$evidence_dir/fork-evidence.json" "$status" "$forge_exit_code" "$reason" \
    "$source_commit" "$release_fork_mode" "$fork_block" "$fork_block_hash" "$log_path" <<'PY'
from __future__ import annotations

import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

(
    evidence_path,
    status,
    forge_exit_code,
    reason,
    source_commit,
    fork_mode,
    fork_block,
    fork_block_hash,
    log_path,
) = sys.argv[1:]
log_sha256 = None
log_text = ""
if log_path:
    log_bytes = Path(log_path).read_bytes()
    log_sha256 = hashlib.sha256(log_bytes).hexdigest()
    log_text = log_bytes.decode("utf-8", errors="replace")

expected_suite_counts = {
    "test/BasketRouterFork.t.sol:BasketRouterForkTest": 1,
    "test/BasketRouterUniswapFork.t.sol:BasketRouterUniswapForkTest": 2,
    "test/OneInchFork.t.sol:OneInchForkTest": 2,
    "test/UniswapUniversalFork.t.sol:UniswapUniversalForkTest": 4,
}
observed_suite_counts = {}
duplicate_suite_records = []
for count, suite in re.findall(r"(?m)^Ran ([0-9]+) tests? for ([^\r\n]+)$", log_text):
    if suite in observed_suite_counts:
        duplicate_suite_records.append(suite)
    observed_suite_counts[suite] = int(count)
suite_complete = (
    not duplicate_suite_records
    and observed_suite_counts == expected_suite_counts
)

document = {
    "schemaVersion": 2,
    "mode": "release-evidence",
    "forkMode": fork_mode,
    "blockAuthority": (
        "configured-pinned-history"
        if fork_mode == "pinned-history"
        else "resolved-local-live-snapshot"
    ),
    "status": status,
    "reason": reason,
    "sourceCommit": source_commit,
    "forkBlock": int(fork_block) if fork_block else None,
    "forkBlockHash": fork_block_hash or None,
    "suitePattern": "test/*Fork*.t.sol",
    "expectedSuites": list(expected_suite_counts),
    "expectedSuiteTestCounts": expected_suite_counts,
    "expectedTestCount": sum(expected_suite_counts.values()),
    "observedSuiteTestCounts": observed_suite_counts,
    "observedTestCount": sum(observed_suite_counts.values()),
    "duplicateSuiteRecords": sorted(set(duplicate_suite_records)),
    "suiteCompleteness": suite_complete,
    "processGroupCleanup": (
        None
        if fork_mode == "pinned-history"
        else {
            "anvil": "anvilProcessGroupCleanup=complete" in log_text,
            "forge": "forgeProcessGroupCleanup=complete" in log_text,
        }
    ),
    "forgeExitCode": int(forge_exit_code),
    "sanitizedLogSha256": log_sha256,
    "generatedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
}
Path(evidence_path).write_text(
    json.dumps(document, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
}

if [[ "$mode" == "release-evidence" ]]; then
  source_commit="$(git -C "$ROOT" rev-parse HEAD)"
  expected_commit="${EXPECTED_HELPERS_COMMIT:-}"

  if [[ "$release_fork_mode" != "pinned-history" && "$release_fork_mode" != "live-latest-snapshot" ]]; then
    echo "ERROR: HELPERS_RELEASE_FORK_MODE must be pinned-history or live-latest-snapshot." >&2
    exit 2
  fi
  if [[ -z "$expected_commit" ]]; then
    echo "ERROR: EXPECTED_HELPERS_COMMIT is required for release fork evidence." >&2
    exit 1
  fi
  if [[ ! "$expected_commit" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: EXPECTED_HELPERS_COMMIT must be a lowercase 40-character commit SHA." >&2
    exit 1
  fi
  if [[ "$source_commit" != "$expected_commit" ]]; then
    echo "ERROR: release fork evidence commit mismatch (expected $expected_commit, checked out $source_commit)." >&2
    exit 1
  fi
  if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]]; then
    echo "ERROR: release fork evidence requires a clean exact checkout." >&2
    exit 1
  fi
  if [[ "$release_fork_mode" == "pinned-history" && "$fork_block" != "$PINNED_MAINNET_FORK_BLOCK" ]]; then
    echo "ERROR: release fork evidence must use pinned mainnet block $PINNED_MAINNET_FORK_BLOCK (got $fork_block)." >&2
    exit 1
  fi
  if [[ "$release_fork_mode" == "live-latest-snapshot" && -n "${MAINNET_FORK_BLOCK+x}" ]]; then
    echo "ERROR: live-latest-snapshot resolves its immutable block identity at startup; MAINNET_FORK_BLOCK must be unset." >&2
    exit 1
  fi
fi

if [[ -z "${MAINNET_RPC_URL:-}" ]]; then
  warning="WARNING: HELPERS FORK EVIDENCE UNAVAILABLE — MAINNET_RPC_URL is not set; fork tests were NOT RUN; this is NOT A PASS."
  echo "$warning" >&2
  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "::warning title=Helpers fork evidence unavailable::$warning" >&2
  fi
  if [[ "$mode" == "release-evidence" ]]; then
    write_release_evidence "not-run" "1" "MAINNET_RPC_URL is not set"
    echo "ERROR: release fork evidence is mandatory and fails closed when unavailable." >&2
    exit 1
  fi
  exit 0
fi

# Keep every fork read (including release pre/post checks and snapshot Anvil)
# inside one adapter lifetime. The runner removes the bearer before re-entry.
# Retain a failed attempt if adapter startup or child preflight cannot finish;
# the child replaces it with its actual fork outcome. No stale pass can survive.
if [[ -n "${MAINNET_RPC_BEARER:-}" ]]; then
  if [[ "$mode" == "release-evidence" ]]; then
    write_release_evidence "failed" "1" "authenticated RPC setup or child preflight did not complete"
  fi
  exec python3 "$ROOT/lib/cybergold-protocol/ci/helpers/with-authenticated-rpc.py" -- bash "$ROOT/ci/check-fork-tests.sh" "$@"
fi

if [[ "$mode" == "development" ]]; then
  echo "==> forge test --root $ROOT --match-path test/*Fork*.t.sol --fork-url MAINNET_RPC_URL --fork-block-number $fork_block"
  forge test --root "$ROOT" --match-path "test/*Fork*.t.sol" --fork-url "$MAINNET_RPC_URL" --fork-block-number "$fork_block"
  exit $?
fi

mkdir -p "$evidence_dir"
release_log="$evidence_dir/forge-test.sanitized.log"

if [[ "$release_fork_mode" == "pinned-history" ]]; then
  echo "==> fail-closed release fork at pinned historical block $fork_block"
  raw_log="$(mktemp "${TMPDIR:-/tmp}/helpers-fork-evidence.XXXXXX")"
  snapshot_result="$(mktemp "${TMPDIR:-/tmp}/helpers-pinned-fork-identity.XXXXXX")"
  post_identity="$(mktemp "${TMPDIR:-/tmp}/helpers-pinned-fork-post-identity.XXXXXX")"
  rm -f "$snapshot_result" "$post_identity"

  set +e
  python3 "$ROOT/ci/rpc_block_identity.py" \
    --block-number "$fork_block" \
    --output "$snapshot_result" >"$raw_log" 2>&1
  forge_status=$?
  if [[ "$forge_status" -eq 0 ]]; then
    fork_block_hash="$(python3 - "$snapshot_result" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1], encoding="utf-8"))["forkBlockHash"])
PY
)"
    forge test --root "$ROOT" --match-path "test/*Fork*.t.sol" \
      --fork-url "$MAINNET_RPC_URL" --fork-block-number "$fork_block" >>"$raw_log" 2>&1
    forge_status=$?
  fi
  if [[ "$forge_status" -eq 0 ]]; then
    python3 "$ROOT/ci/rpc_block_identity.py" \
      --block-number "$fork_block" \
      --expected-hash "$fork_block_hash" \
      --output "$post_identity" >>"$raw_log" 2>&1
    forge_status=$?
  fi
  set -e

  python3 - "$ROOT/ci" "$raw_log" "$release_log" <<'PY'
from pathlib import Path
import sys

sys.path.insert(0, sys.argv[1])
from rpc_secret_sanitizer import sanitize_rpc_text

source, destination = sys.argv[2:]
text = Path(source).read_text(encoding="utf-8", errors="replace")
secret = __import__("os").environ["MAINNET_RPC_URL"]
Path(destination).write_text(
    sanitize_rpc_text(
        text,
        secret,
        url_replacement="<redacted-rpc-url>",
        credential_replacement="<redacted-rpc-credential>",
    ),
    encoding="utf-8",
)
PY
  failure_reason="pinned historical RPC identity or fork suite failed"
  success_reason="pinned historical fork suite passed"
else
  echo "==> fail-closed release fork at one locally pinned live upstream snapshot"
  snapshot_result="$(mktemp "${TMPDIR:-/tmp}/helpers-live-fork-result.XXXXXX")"
  rm -f "$snapshot_result"

  set +e
  python3 "$ROOT/ci/run-live-fork-snapshot.py" \
    --root "$ROOT" \
    --log "$release_log" \
    --result "$snapshot_result"
  forge_status=$?
  set -e

  if [[ -f "$snapshot_result" ]]; then
    fork_block="$(python3 - "$snapshot_result" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8")).get("forkBlock")
print("" if value is None else value)
PY
)"
    fork_block_hash="$(python3 - "$snapshot_result" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8")).get("forkBlockHash")
print("" if value is None else value)
PY
)"
  fi
  failure_reason="live latest snapshot fork suite failed"
  success_reason="live latest snapshot fork suite passed"
fi

if [[ "$forge_status" -ne 0 ]]; then
  write_release_evidence "failed" "$forge_status" "$failure_reason" "$release_log"
  echo "ERROR: release fork evidence failed; sanitized diagnostics retained in $evidence_dir." >&2
  exit "$forge_status"
fi

for index in "${!EXPECTED_FORK_SUITES[@]}"; do
  expected_suite="${EXPECTED_FORK_SUITES[$index]}"
  expected_count="${EXPECTED_FORK_TEST_COUNTS[$index]}"
  test_label="tests"
  if [[ "$expected_count" == "1" ]]; then
    test_label="test"
  fi
  if ! grep -Fq "Ran $expected_count $test_label for $expected_suite" "$release_log"; then
    write_release_evidence \
      "failed" "1" "successful forge exit omitted expected $expected_count-test suite $expected_suite" "$release_log"
    echo "ERROR: release fork evidence omitted the complete $expected_count-test suite $expected_suite." >&2
    exit 1
  fi
done

if ! python3 - "$release_log" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

expected = {
    "test/BasketRouterFork.t.sol:BasketRouterForkTest": 1,
    "test/BasketRouterUniswapFork.t.sol:BasketRouterUniswapForkTest": 2,
    "test/OneInchFork.t.sol:OneInchForkTest": 2,
    "test/UniswapUniversalFork.t.sol:UniswapUniversalForkTest": 4,
}
observed = {}
duplicates = []
text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
for count, suite in re.findall(r"(?m)^Ran ([0-9]+) tests? for ([^\r\n]+)$", text):
    if suite in observed:
        duplicates.append(suite)
    observed[suite] = int(count)
if duplicates or observed != expected:
    print(
        "ERROR: release fork evidence suite inventory is not exactly the "
        f"approved four-suite/nine-test set (observed={observed!r}, duplicates={duplicates!r}).",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY
then
  write_release_evidence \
    "failed" "1" "forge output did not contain exactly the approved four-suite/nine-test inventory" "$release_log"
  exit 1
fi

if [[ "$(git -C "$ROOT" rev-parse HEAD)" != "$source_commit" ]]; then
  write_release_evidence \
    "failed" "1" "release fork execution changed the candidate commit" "$release_log"
  echo "ERROR: release fork execution changed the candidate commit." >&2
  exit 1
fi
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]]; then
  write_release_evidence \
    "failed" "1" "release fork execution changed the exact candidate checkout" "$release_log"
  echo "ERROR: release fork execution changed the exact candidate checkout." >&2
  exit 1
fi

write_release_evidence "passed" "0" "$success_reason" "$release_log"
echo "Helpers release fork evidence PASSED for commit $source_commit in $release_fork_mode mode at mainnet block $fork_block."
if [[ -n "$fork_block_hash" ]]; then
  echo "Resolved immutable snapshot block hash: $fork_block_hash"
fi
echo "All ${#EXPECTED_FORK_SUITES[@]} expected suites / $EXPECTED_FORK_TEST_TOTAL tests completed."
echo "Sanitized release evidence retained in $evidence_dir."
