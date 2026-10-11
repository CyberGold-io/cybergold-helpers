#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBMODULE_PATH="lib/cybergold-protocol"
SUBMODULE_DIR="${ROOT_DIR}/${SUBMODULE_PATH}"
FOUNDRY_LOCK="${ROOT_DIR}/foundry.lock"
UPSTREAM_REMOTE_NAME="${UPSTREAM_REMOTE_NAME:-github}"
UPSTREAM_REMOTE_URL="${UPSTREAM_REMOTE_URL:-https://github.com/CyberGold-io/cybergold-protocol.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"

if [ ! -d "${SUBMODULE_DIR}/.git" ]; then
  git -C "${ROOT_DIR}" submodule update --init --recursive "${SUBMODULE_PATH}"
fi

PREV_SHA="$(git -C "${SUBMODULE_DIR}" rev-parse --short HEAD 2>/dev/null || echo "none")"

if git -C "${SUBMODULE_DIR}" remote get-url "${UPSTREAM_REMOTE_NAME}" >/dev/null 2>&1; then
  current_upstream_url="$(git -C "${SUBMODULE_DIR}" remote get-url "${UPSTREAM_REMOTE_NAME}")"
  if [ "${current_upstream_url}" != "${UPSTREAM_REMOTE_URL}" ]; then
    git -C "${SUBMODULE_DIR}" remote set-url "${UPSTREAM_REMOTE_NAME}" "${UPSTREAM_REMOTE_URL}"
  fi
else
  git -C "${SUBMODULE_DIR}" remote add "${UPSTREAM_REMOTE_NAME}" "${UPSTREAM_REMOTE_URL}"
fi

git -C "${SUBMODULE_DIR}" fetch "${UPSTREAM_REMOTE_NAME}" "${UPSTREAM_BRANCH}" --prune

if git -C "${SUBMODULE_DIR}" show-ref --verify --quiet "refs/remotes/origin/${UPSTREAM_BRANCH}"; then
  if git -C "${SUBMODULE_DIR}" merge-base --is-ancestor \
    "${UPSTREAM_REMOTE_NAME}/${UPSTREAM_BRANCH}" "origin/${UPSTREAM_BRANCH}" >/dev/null 2>&1; then
    ahead_count="$(git -C "${SUBMODULE_DIR}" rev-list --count "${UPSTREAM_REMOTE_NAME}/${UPSTREAM_BRANCH}..origin/${UPSTREAM_BRANCH}")"
    if [ "${ahead_count}" -gt 0 ]; then
      echo "WARNING: local origin/${UPSTREAM_BRANCH} is ${ahead_count} commit(s) ahead of ${UPSTREAM_REMOTE_NAME}/${UPSTREAM_BRANCH}." >&2
      echo "         You probably have local cybergold-protocol commits that are not pushed to GitHub yet." >&2
      echo "         Submodule pin will use ${UPSTREAM_REMOTE_NAME}/${UPSTREAM_BRANCH} to keep CI-compatible refs." >&2
    fi
  fi
fi

git -C "${SUBMODULE_DIR}" checkout -q --detach "${UPSTREAM_REMOTE_NAME}/${UPSTREAM_BRANCH}"
git -C "${SUBMODULE_DIR}" submodule update --init --recursive

NEW_FULL_SHA="$(git -C "${SUBMODULE_DIR}" rev-parse HEAD)"
NEW_SHA="$(git -C "${SUBMODULE_DIR}" rev-parse --short HEAD)"

python3 - "${FOUNDRY_LOCK}" "${SUBMODULE_PATH}" "${NEW_FULL_SHA}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
dependency = sys.argv[2]
revision = sys.argv[3]
lock = json.loads(path.read_text(encoding="utf-8"))
lock.setdefault(dependency, {})["rev"] = revision
path.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
PY

git -C "${ROOT_DIR}" add "${SUBMODULE_PATH}" "${FOUNDRY_LOCK}"

echo "Pinned ${SUBMODULE_PATH} from ${PREV_SHA} to ${NEW_SHA} (${UPSTREAM_REMOTE_NAME}/${UPSTREAM_BRANCH})."
