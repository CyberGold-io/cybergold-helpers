#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers/bootstrap.sh"

FOUNDRY_LOCK_PATH="${FOUNDRY_LOCK_PATH:-$ROOT/foundry.lock}"

python3 - "$FOUNDRY_LOCK_PATH" "$ROOT/.gitmodules" <<'PY'
import configparser
import json
import pathlib
import re
import sys

lock = json.loads(pathlib.Path(sys.argv[1]).read_text())
modules = configparser.ConfigParser()
modules.read(sys.argv[2])
expected_paths = {section["path"] for section in modules.values() if "path" in section}
if not expected_paths:
    raise SystemExit("no production submodules declared in .gitmodules")
if set(lock) != expected_paths:
    missing = sorted(expected_paths - set(lock))
    extra = sorted(set(lock) - expected_paths)
    raise SystemExit(f"foundry.lock submodule set mismatch; missing={missing}, extra={extra}")
for path in sorted(expected_paths):
    revision = lock.get(path, {}).get("rev", "")
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise SystemExit(f"foundry.lock has no full commit revision for {path}")
PY

while IFS= read -r relative_path; do
  submodule_path="$ROOT/$relative_path"
  if [ ! -e "$submodule_path/.git" ]; then
    echo "ERROR: submodule missing at $submodule_path (did you run git submodule update --init --recursive?)" >&2
    exit 1
  fi
  if ! git -C "$submodule_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: $submodule_path is not a git repository" >&2
    exit 1
  fi

  echo "==> Exact submodule pin check for $submodule_path"
  current_commit="$(git -C "$submodule_path" rev-parse HEAD)"
  expected_commit="$(git -C "$ROOT" ls-files --stage "$relative_path" | awk '{print $2}')"
  if [ -z "$expected_commit" ]; then
    echo "ERROR: unable to resolve expected commit for $relative_path from the gitlink" >&2
    exit 1
  fi
  if [ "$relative_path" = "lib/cybergold-protocol" ] && [ -n "${EXPECTED_PROTOCOL_COMMIT:-}" ] \
    && [ "$EXPECTED_PROTOCOL_COMMIT" != "$expected_commit" ]; then
    echo "ERROR: Protocol release input does not match the exact gitlink" >&2
    echo "  release : $EXPECTED_PROTOCOL_COMMIT" >&2
    echo "  gitlink : $expected_commit" >&2
    exit 1
  fi

  locked_commit="$(python3 - "$FOUNDRY_LOCK_PATH" "$relative_path" <<'PY'
import json
import pathlib
import sys

print(json.loads(pathlib.Path(sys.argv[1]).read_text())[sys.argv[2]]["rev"])
PY
)"
  if [ "$locked_commit" != "$expected_commit" ]; then
    echo "ERROR: foundry.lock revision for $relative_path does not match the exact gitlink" >&2
    echo "  lock    : $locked_commit" >&2
    echo "  gitlink : $expected_commit" >&2
    exit 1
  fi
  if [ "$current_commit" != "$expected_commit" ]; then
    echo "ERROR: checkout for $relative_path does not match the exact required commit" >&2
    echo "  current : $current_commit" >&2
    echo "  expected: $expected_commit" >&2
    exit 1
  fi
  dirty_state="$(git -C "$submodule_path" status --porcelain --untracked-files=all)"
  if [ -n "$dirty_state" ]; then
    echo "ERROR: submodule checkout is dirty at $relative_path" >&2
    echo "$dirty_state" >&2
    exit 1
  fi
  echo "Submodule pin and worktree match: $relative_path @ $current_commit"
done < <(git -C "$ROOT" config --file .gitmodules --get-regexp path | awk '{print $2}' | LC_ALL=C sort)
