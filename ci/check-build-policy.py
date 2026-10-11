#!/usr/bin/env python3
"""Enforce the single Helpers compiler and optimizer authority."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FOUNDRY_CONFIG = ROOT / "foundry.toml"
STORAGE_CONFIG = ROOT / "ci" / "storage-inventory.config.json"
STORAGE_INVENTORY = ROOT / "ci" / "storage-inventory.json"
EXPECTED_SOLC = "0.8.37"
EXPECTED_EVM = "osaka"
EXPECTED_OPTIMIZER_RUNS = 100
AUTHORITY_ROOTS = (ROOT / "ci", ROOT / "script", ROOT / ".github" / "workflows")
AUTHORITY_SUFFIXES = {".json", ".py", ".sh", ".sol", ".toml", ".yaml", ".yml"}
OVERRIDE_PATTERNS = {
    re.compile(r"(?<![A-Za-z0-9_])--evm-version(?:=|\s)"): "CLI EVM override",
    re.compile(r"(?<![A-Za-z0-9_])--optimizer-runs(?:=|\s)"): "CLI optimizer-runs override",
    re.compile(r"\bFOUNDRY_EVM_VERSION\b"): "environment EVM override",
    re.compile(r"\bFOUNDRY_OPTIMIZER_RUNS\b"): "environment optimizer-runs override",
}


def foundry_policy_errors(text: str) -> list[str]:
    section = re.search(r"(?ms)^\[profile\.default\]\s*$\n(?P<body>.*?)(?=^\[|\Z)", text)
    if section is None:
        return ["foundry.toml is missing [profile.default]"]

    expected = {
        "solc_version": f'"{EXPECTED_SOLC}"',
        "evm_version": f'"{EXPECTED_EVM}"',
        "optimizer": "true",
        "optimizer_runs": str(EXPECTED_OPTIMIZER_RUNS),
    }
    values = {
        match.group("key"): match.group("value").strip()
        for match in re.finditer(
            r"(?m)^\s*(?P<key>[A-Za-z0-9_]+)\s*=\s*(?P<value>[^#\n]+)",
            section.group("body"),
        )
    }
    return [
        f"foundry.toml profile.default.{key} must be {value}, got {values.get(key)!r}"
        for key, value in expected.items()
        if values.get(key) != value
    ]


def storage_policy_errors(config: dict[str, object], *, label: str) -> list[str]:
    compiler = config.get("compiler")
    if not isinstance(compiler, dict):
        return [f"{label} is missing its compiler identity"]
    errors: list[str] = []
    if compiler.get("version") != EXPECTED_SOLC:
        errors.append(f"{label} compiler version must be {EXPECTED_SOLC}")
    if compiler.get("evmVersion") != EXPECTED_EVM:
        errors.append(f"{label} EVM version must be {EXPECTED_EVM}")
    return errors


def authority_override_errors(paths: list[Path]) -> list[str]:
    errors: list[str] = []
    for path in paths:
        if path == Path(__file__).resolve() or path.suffix not in AUTHORITY_SUFFIXES:
            continue
        text = path.read_text(encoding="utf-8")
        for pattern, label in OVERRIDE_PATTERNS.items():
            if pattern.search(text):
                errors.append(f"{path.relative_to(ROOT)} contains a divergent {label}")
    return errors


def validate_fixtures() -> None:
    good = (
        "[profile.default]\n"
        f'solc_version = "{EXPECTED_SOLC}"\n'
        f'evm_version = "{EXPECTED_EVM}"\n'
        "optimizer = true\n"
        f"optimizer_runs = {EXPECTED_OPTIMIZER_RUNS}\n"
    )
    if foundry_policy_errors(good):
        raise ValueError("canonical build-policy fixture unexpectedly failed")
    bad = good.replace(f"optimizer_runs = {EXPECTED_OPTIMIZER_RUNS}", "optimizer_runs = 10000")
    if not foundry_policy_errors(bad):
        raise ValueError("divergent optimizer fixture unexpectedly passed")


def main() -> int:
    validate_fixtures()
    errors = foundry_policy_errors(FOUNDRY_CONFIG.read_text(encoding="utf-8"))
    errors.extend(
        storage_policy_errors(
            json.loads(STORAGE_CONFIG.read_text(encoding="utf-8")),
            label=str(STORAGE_CONFIG.relative_to(ROOT)),
        )
    )
    errors.extend(
        storage_policy_errors(
            json.loads(STORAGE_INVENTORY.read_text(encoding="utf-8")),
            label=str(STORAGE_INVENTORY.relative_to(ROOT)),
        )
    )

    first_party_configs = [
        path
        for path in ROOT.rglob("foundry.toml")
        if not any(part in {".git", "broadcast", "cache", "lib", "out"} for part in path.relative_to(ROOT).parts)
    ]
    if first_party_configs != [FOUNDRY_CONFIG]:
        errors.append(
            "Helpers must have exactly one first-party foundry.toml authority; "
            f"found {[str(path.relative_to(ROOT)) for path in first_party_configs]}"
        )

    authority_paths = sorted(
        path
        for authority_root in AUTHORITY_ROOTS
        for path in authority_root.rglob("*")
        if path.is_file()
    )
    errors.extend(authority_override_errors(authority_paths))

    if errors:
        print("Helpers build policy validation failed:")
        for error in errors:
            print(f"- {error}")
        return 1

    print(
        "Helpers build policy passed "
        f"(Solidity {EXPECTED_SOLC}, EVM {EXPECTED_EVM}, optimizer runs {EXPECTED_OPTIMIZER_RUNS}; "
        "one Foundry authority and no per-command overrides)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
