#!/usr/bin/env python3
"""Enforce the Helpers-specific exact read-only workflow permission policy."""

from __future__ import annotations

import re
import stat
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_DIR = ROOT / ".github" / "workflows"
# The pinned Protocol checker owns third-party Action parsing and its mutable-ref
# fixtures. This repository retains only the stricter Helpers token-permission rule.
READ_ONLY_BASELINE = "\npermissions:\n  contents: read\n\njobs:\n"
WRITE_PERMISSION_RE = re.compile(
    r"(?m)^\s*(?:permissions:\s*write-all|[a-z-]+:\s*write)(?:\s+#.*)?\s*$"
)
ACTION_USE_RE = re.compile(r"^\s*(?:-\s*)?uses:\s*([^@\s]+)@([0-9a-f]{40})(?:\s+#.*)?$")
APPROVED_ACTION_REVISIONS = {
    "actions/checkout": "3d3c42e5aac5ba805825da76410c181273ba90b1",  # v7.0.1
    "astral-sh/setup-uv": "c18668ad3cf93ea998bef934396af7bb5c839dc7",  # v10.2.0
}


def permission_errors(text: str) -> list[str]:
    errors: list[str] = []
    if READ_ONLY_BASELINE not in text:
        errors.append("top-level permissions must contain only contents: read")
    if WRITE_PERMISSION_RE.search(text):
        errors.append("write-capable workflow token permission is not approved")
    return errors


def dependency_action_errors(text: str) -> list[str]:
    errors: list[str] = []
    lines = text.splitlines()
    for index, line in enumerate(lines):
        match = ACTION_USE_RE.match(line)
        if match is None:
            continue
        action, revision = match.groups()
        approved_revision = APPROVED_ACTION_REVISIONS.get(action)
        if approved_revision is not None and revision != approved_revision:
            errors.append(f"{action} must use reviewed revision {approved_revision}")
        if action == "astral-sh/setup-uv":
            option_block = "\n".join(lines[index + 1 : index + 5])
            if "enable-cache: true" not in option_block:
                errors.append("setup-uv caching must be explicit")
            if "prune-cache: true" not in option_block:
                errors.append("setup-uv cache pruning must be explicit")
    return errors


def advisory_monitor_errors(text: str) -> list[str]:
    errors: list[str] = []
    if not text.startswith("name: Advisory "):
        errors.append("live dependency discovery workflow must be labeled advisory")
    if "  schedule:" not in text or "  workflow_dispatch:" not in text:
        errors.append("advisory discovery must retain scheduled/manual triggers")
    if re.search(r"(?m)^  (?:push|pull_request):", text):
        errors.append("live dependency discovery must not run as candidate push/PR authority")
    if "--check-upstream" not in text:
        errors.append("advisory discovery command is missing")
    return errors


def release_fork_evidence_errors(text: str) -> list[str]:
    errors: list[str] = []
    required_fragments = (
        "  workflow_dispatch:",
        "      expected_commit:",
        "      fork_mode:",
        "        required: true",
        "        default: pinned-history",
        "        type: choice",
        "          - pinned-history",
        "          - live-latest-snapshot",
        'test "${EXPECTED_HELPERS_COMMIT}" = "${GITHUB_SHA}"',
        'test "$(git rev-parse HEAD)" = "${GITHUB_SHA}"',
        "ci/check-fork-tests.sh --release-evidence",
        "HELPERS_RELEASE_FORK_MODE: ${{ inputs.fork_mode }}",
        "MAINNET_RPC_URL: ${{ secrets.MAINNET_RPC_URL }}",
        "HELPERS_FORK_EVIDENCE_OUT: ${{ runner.temp }}/release-fork-evidence",
        "if: always()",
        "helpers-release-fork-${{ github.sha }}-${{ inputs.fork_mode }}",
        "path: ${{ runner.temp }}/release-fork-evidence/",
        "if-no-files-found: error",
    )
    errors.extend(
        f"required release-evidence control is missing: {fragment}"
        for fragment in required_fragments
        if fragment not in text
    )
    if re.search(r"(?m)^  (?:push|pull_request|schedule):", text):
        errors.append("release fork evidence must remain an explicit manual dispatch")
    if "continue-on-error:" in text:
        errors.append("release fork evidence must not continue after a failed control")
    if "vars.MAINNET_RPC_URL" in text:
        errors.append("release fork evidence must consume the protected RPC secret, not a public variable")
    if text.count("ci/check-fork-tests.sh --release-evidence") != 1:
        errors.append("release fork evidence must execute exactly one explicitly selected mode")
    return errors


def validate_fixtures() -> None:
    read_only = "name: fixture\npermissions:\n  contents: read\n\njobs:\n  test:\n"
    missing = "name: fixture\njobs:\n  test:\n"
    write_capable = (
        "name: fixture\npermissions:\n  contents: read\n\njobs:\n"
        "  publish:\n    permissions:\n      packages: write # unapproved fixture\n"
    )
    if permission_errors(read_only):
        raise ValueError("read-only workflow permission fixture unexpectedly failed")
    if not permission_errors(missing):
        raise ValueError("missing-permission negative fixture unexpectedly passed")
    if not permission_errors(write_capable):
        raise ValueError("write-capable permission negative fixture unexpectedly passed")

    checkout = APPROVED_ACTION_REVISIONS["actions/checkout"]
    setup_uv = APPROVED_ACTION_REVISIONS["astral-sh/setup-uv"]
    reviewed_actions = (
        f"      uses: actions/checkout@{checkout} # reviewed\n"
        f"      uses: astral-sh/setup-uv@{setup_uv} # reviewed\n"
        "      with:\n"
        "        enable-cache: true\n"
        "        prune-cache: true\n"
    )
    if dependency_action_errors(reviewed_actions):
        raise ValueError("reviewed Action fixture unexpectedly failed")
    stale_checkout = reviewed_actions.replace(checkout, "0" * 40)
    if not dependency_action_errors(stale_checkout):
        raise ValueError("stale Action fixture unexpectedly passed")
    unpruned_cache = reviewed_actions.replace("        prune-cache: true\n", "")
    if not dependency_action_errors(unpruned_cache):
        raise ValueError("unpruned setup-uv fixture unexpectedly passed")

    advisory = (
        "name: Advisory dependency monitor\n"
        "on:\n"
        "  schedule:\n"
        '    - cron: "0 0 * * *"\n'
        "  workflow_dispatch:\n"
        "jobs:\n"
        "  advisory:\n"
        "    steps:\n"
        "      - run: python3 monitor.py --check-upstream\n"
    )
    if advisory_monitor_errors(advisory):
        raise ValueError("advisory dependency-monitor fixture unexpectedly failed")
    if not advisory_monitor_errors(advisory.replace("  workflow_dispatch:\n", "  pull_request:\n")):
        raise ValueError("candidate-triggered live-discovery fixture unexpectedly passed")


def main() -> int:
    validate_fixtures()
    errors: list[str] = []
    workflows = sorted((*WORKFLOW_DIR.glob("*.yml"), *WORKFLOW_DIR.glob("*.yaml")))
    for path in workflows:
        text = path.read_text(encoding="utf-8")
        relative = path.relative_to(ROOT)
        errors.extend(f"{relative}: {error}" for error in permission_errors(text))
        errors.extend(f"{relative}: {error}" for error in dependency_action_errors(text))
        if path.name == "router-release-alert.yml":
            errors.extend(f"{relative}: {error}" for error in advisory_monitor_errors(text))
        elif path.name == "release-fork-evidence.yml":
            errors.extend(f"{relative}: {error}" for error in release_fork_evidence_errors(text))
        elif "--check-upstream" in text:
            errors.append(f"{relative}: live upstream discovery is forbidden in candidate CI")
    fork_gate = ROOT / "ci" / "check-fork-tests.sh"
    if not fork_gate.stat().st_mode & stat.S_IXUSR:
        errors.append("ci/check-fork-tests.sh must remain executable for the release workflow")

    if errors:
        print("Helpers workflow policy validation failed:")
        for error in errors:
            print(f"- {error}")
        return 1
    print(f"Helpers workflow permission policy passed ({len(workflows)} workflows; fixtures verified).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
