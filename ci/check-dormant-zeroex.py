#!/usr/bin/env python3
"""Keep the dormant ZeroEx adapter frozen and outside every active surface."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FROZEN_SOURCE = ROOT / "src" / "adapters" / "ZeroExAdapter.sol"
FROZEN_SHA256 = "57a7a1be9471f504e25df174b6484521ca0c03b7f0a6c21c15b45eb220dbabf2"
HISTORICAL_PRAGMA = b"\npragma solidity ^0.8.36;\n"
APPROVED_PRAGMA = b"\npragma solidity ^0.8.37;\n"
ACTIVE_ROOTS = (
    ROOT / "src",
    ROOT / "script",
    ROOT / "config",
    ROOT / "generated",
    ROOT / "test",
)
ACTIVE_SUFFIXES = {".json", ".sol"}
ZEROEX_RE = re.compile(r"zero[\s_-]*ex", re.IGNORECASE)


def frozen_source_errors(source: bytes) -> list[str]:
    # Owner-approved on 2026-09-15: only this exact pragma synchronization is
    # exempt from the historical source freeze; every other byte remains bound.
    historical = source.replace(APPROVED_PRAGMA, HISTORICAL_PRAGMA, 1)
    actual = hashlib.sha256(historical).hexdigest()
    if actual == FROZEN_SHA256:
        return []
    return [
        "src/adapters/ZeroExAdapter.sol differs from its frozen source after "
        "the sole approved 0.8.37-to-0.8.36 pragma normalization; "
        f"expected historical SHA-256 {FROZEN_SHA256}, got {actual}. "
        "Explicit production requalification is required before changing this source."
    ]


def active_surface_errors(surfaces: list[tuple[Path, str]]) -> list[str]:
    return [
        f"{path}: dormant ZeroEx adapter re-entered an active integration, deployment, release, or test surface"
        for path, text in surfaces
        if ZEROEX_RE.search(text)
    ]


def validate_fixtures(source: bytes) -> None:
    if active_surface_errors([(Path("src/deploy/AdapterDeployer.sol"), "OneInchAdapter")]):
        raise ValueError("non-ZeroEx active-surface fixture unexpectedly failed")
    if not active_surface_errors([(Path("src/deploy/AdapterDeployer.sol"), "new ZeroExAdapter()")]):
        raise ValueError("ZeroEx re-entry fixture unexpectedly passed")
    if not frozen_source_errors(b"modified dormant source"):
        raise ValueError("modified frozen-source fixture unexpectedly passed")
    historical = source.replace(APPROVED_PRAGMA, HISTORICAL_PRAGMA, 1)
    if frozen_source_errors(historical):
        raise ValueError("historical frozen-source fixture unexpectedly failed")
    approved = historical.replace(HISTORICAL_PRAGMA, APPROVED_PRAGMA, 1)
    if frozen_source_errors(approved):
        raise ValueError("approved pragma-only fixture unexpectedly failed")
    future = historical.replace(HISTORICAL_PRAGMA, b"\npragma solidity ^0.8.38;\n", 1)
    if not frozen_source_errors(future):
        raise ValueError("unapproved future-pragma fixture unexpectedly passed")
    if not frozen_source_errors(approved.replace(b"contract ZeroExAdapter", b"contract ChangedAdapter", 1)):
        raise ValueError("dormant adapter body-drift fixture unexpectedly passed")
    if not frozen_source_errors(approved + b"// unapproved comment\n"):
        raise ValueError("dormant adapter comment-drift fixture unexpectedly passed")


def main() -> int:
    source = FROZEN_SOURCE.read_bytes()
    errors = frozen_source_errors(source)
    if not errors:
        validate_fixtures(source)

    surfaces: list[tuple[Path, str]] = []
    for active_root in ACTIVE_ROOTS:
        if not active_root.exists():
            continue
        for path in sorted(active_root.rglob("*")):
            if not path.is_file() or path == FROZEN_SOURCE or path.suffix not in ACTIVE_SUFFIXES:
                continue
            surfaces.append((path.relative_to(ROOT), path.read_text(encoding="utf-8")))
    errors.extend(active_surface_errors(surfaces))

    coverage_gate = (ROOT / "ci" / "check-coverage.sh").read_text(encoding="utf-8")
    coverage_exclusions = re.findall(r'--no-match-coverage\s+"([^"]+)"', coverage_gate)
    if not any("src/adapters/ZeroExAdapter.sol" in exclusion.split("|") for exclusion in coverage_exclusions):
        errors.append("ci/check-coverage.sh no longer excludes the unqualified frozen source")

    if errors:
        print("Dormant ZeroEx policy validation failed:")
        for error in errors:
            print(f"- {error}")
        return 1

    print(
        "Dormant ZeroEx policy passed "
        "(historical source hash frozen except the owner-approved 0.8.37 pragma; "
        "no deployment, release, generated ABI, or qualification re-entry)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
