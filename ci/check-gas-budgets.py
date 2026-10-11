#!/usr/bin/env python3
"""Validate current critical-route gas against a tracked baseline and hard ceilings."""

from __future__ import annotations

import argparse
import json
import math
import re
from pathlib import Path


LINE_RE = re.compile(r"^(?P<route>.+\(\)) \(gas: (?P<gas>[0-9]+)\)$")


def load_snapshot(path: Path) -> dict[str, int]:
    routes: dict[str, int] = {}
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        match = LINE_RE.fullmatch(raw)
        if match is None:
            raise ValueError(f"{path}:{line_number}: malformed gas snapshot line")
        route = match.group("route")
        if route in routes:
            raise ValueError(f"{path}:{line_number}: duplicate route {route}")
        routes[route] = int(match.group("gas"))
    return routes


def render_snapshot(routes: dict[str, int]) -> str:
    return "".join(f"{route} (gas: {routes[route]})\n" for route in sorted(routes))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--current", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--budgets", type=Path, required=True)
    parser.add_argument("--update", action="store_true")
    args = parser.parse_args()

    current = load_snapshot(args.current)
    policy = json.loads(args.budgets.read_text(encoding="utf-8"))
    budgets = policy.get("routes")
    regression_percent = policy.get("maximumRegressionPercent")
    if not isinstance(budgets, dict) or not budgets:
        raise SystemExit("Gas budget policy has no routes.")
    if not isinstance(regression_percent, int) or not 0 <= regression_percent <= 100:
        raise SystemExit("Gas budget policy has an invalid maximumRegressionPercent.")

    expected_routes = set(budgets)
    if set(current) != expected_routes:
        raise SystemExit(
            "Current gas route set differs from policy: "
            f"missing={sorted(expected_routes - set(current))}, extra={sorted(set(current) - expected_routes)}"
        )

    errors: list[str] = []
    for route, gas in sorted(current.items()):
        ceiling = budgets[route]
        if not isinstance(ceiling, int) or ceiling <= 0:
            errors.append(f"{route}: invalid absolute budget {ceiling!r}")
        elif gas > ceiling:
            errors.append(f"{route}: current {gas} exceeds absolute budget {ceiling}")

    if args.update:
        if errors:
            raise SystemExit("Gas budget validation failed:\n- " + "\n- ".join(errors))
        args.baseline.write_text(render_snapshot(current), encoding="utf-8")
        print(f"Updated critical-route gas baseline ({len(current)} routes).")
        return 0

    baseline = load_snapshot(args.baseline)
    if set(baseline) != expected_routes:
        errors.append(
            "tracked baseline route set differs from policy: "
            f"missing={sorted(expected_routes - set(baseline))}, extra={sorted(set(baseline) - expected_routes)}"
        )
    else:
        for route, gas in sorted(current.items()):
            relative_ceiling = math.ceil(baseline[route] * (100 + regression_percent) / 100)
            if gas > relative_ceiling:
                errors.append(
                    f"{route}: current {gas} exceeds {regression_percent}% regression ceiling {relative_ceiling} "
                    f"from baseline {baseline[route]}"
                )

    if errors:
        raise SystemExit("Gas budget validation failed:\n- " + "\n- ".join(errors))
    print(
        f"Critical-route gas validation passed ({len(current)} routes; "
        f"{regression_percent}% relative and absolute ceilings)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
