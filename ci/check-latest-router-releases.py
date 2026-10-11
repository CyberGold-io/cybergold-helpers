#!/usr/bin/env python3
"""Enforce the reviewed router lock and optionally report upstream changes."""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
LOCK_PATH = ROOT / "ci" / "router-dependency-lock.json"
ONEINCH_RELEASES_URL = (
    "https://raw.githubusercontent.com/1inch/limit-order-protocol/master/README.md"
)
UNISWAP_RELEASES_URL = "https://raw.githubusercontent.com/Uniswap/contracts/main/deployments/json/1.json"
FORK_TESTS = (
    ROOT / "test" / "OneInchFork.t.sol",
    ROOT / "test" / "BasketRouterFork.t.sol",
    ROOT / "test" / "UniswapUniversalFork.t.sol",
    ROOT / "test" / "BasketRouterUniswapFork.t.sol",
)
ADDRESS_RE = r"0x[a-fA-F0-9]{40}"


def fetch_text(url: str) -> str:
    request = urllib.request.Request(
        url,
        headers={"Accept": "text/plain, application/json", "User-Agent": "cybergold-ci"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read().decode()
    except (OSError, TimeoutError, UnicodeDecodeError, urllib.error.URLError) as exc:
        raise AssertionError(f"unable to query stable router releases from {url}: {exc}") from exc


def latest_oneinch_release(document: str) -> tuple[str, str]:
    # 1inch changed its deployment list to a Markdown table in August 2026.
    # Support both separators and keep the address on the Ethereum row.
    matches = re.findall(
        rf"1inch Router v(\d+).*?Ethereum mainnet[ \t]*[:|][^\r\n]*?({ADDRESS_RE})",
        document,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if not matches:
        raise AssertionError("official 1inch release source has no Ethereum router deployment")
    major, address = max(matches, key=lambda item: int(item[0]))
    return major, address


def validate_fixtures() -> None:
    address = "0x111111125421cA6dc452d289314280a0f8842A65"
    other_address = "0x6fd4383cB451173D5f9304F041C7BCBf27d561fF"
    legacy = (
        "You can find 1inch Router v6 and 1inch Limit Order protocol v4 deployments here:\n\n"
        f"**Ethereum mainnet:**\u00a0[{address}](https://etherscan.io/address/{address})\n"
    )
    table = (
        "The protocol ships as part of the 1inch Router v6 contract, so 1inch Router v6 "
        "and 1inch Limit Order protocol v4 share a single address on each network:\n\n"
        "| Network          | Contract Address |\n"
        "|------------------|------------------|\n"
        f"| Ethereum mainnet | [`{address}`](https://etherscan.io/address/{address}) |\n"
        f"| zkSync Era       | [`{other_address}`](https://explorer.zksync.io/address/{other_address}) |\n"
    )
    for label, document in (("legacy list", legacy), ("deployment table", table)):
        if latest_oneinch_release(document) != ("6", address):
            raise AssertionError(f"1inch {label} fixture did not select the Ethereum router")

    central = json.dumps({'latest': {'UniversalRouter#v2.1.1': {'address': address},
        'UniversalRouter#v2.2': {'address': other_address}}})
    if latest_uniswap_release(central) != ('2.2', other_address):
        raise AssertionError('central Uniswap deployment fixture did not select V2.2')

    # An empty Ethereum row must not borrow an address from another network.
    missing_address = table.replace(f"[`{address}`](https://etherscan.io/address/{address})", "pending")
    try:
        latest_oneinch_release(missing_address)
    except AssertionError:
        pass
    else:
        raise AssertionError("1inch fixture accepted another network's router for Ethereum")


def latest_uniswap_release(document: str) -> tuple[str, str]:
    try:
        deployments: Any = json.loads(document)
    except json.JSONDecodeError as exc:
        raise AssertionError("official Uniswap deployment source is not valid JSON") from exc
    if not isinstance(deployments, dict):
        raise AssertionError("official Uniswap deployment source must be a JSON object")

    candidates: list[tuple[tuple[int, ...], str]] = []
    for label, address in deployments.get('latest', deployments).items():
        if isinstance(address, dict):
            address = address.get('address')
        central = re.fullmatch(r"UniversalRouter#v(\d+(?:\.\d+)*)", str(label))
        if central and isinstance(address, str) and re.fullmatch(ADDRESS_RE, address):
            candidates.append((tuple(map(int, central.group(1).split('.'))), address))
        match = re.fullmatch(r"UniversalRouterV(\d+(?:_\d+)*)", str(label))
        if match and isinstance(address, str) and re.fullmatch(ADDRESS_RE, address):
            candidates.append((tuple(map(int, match.group(1).split("_"))), address))
    if not candidates:
        raise AssertionError("official Uniswap deployment source has no stable router deployment")
    version, address = max(candidates)
    return ".".join(map(str, version)), address


def require_address(label: str, actual: object, expected: str, source: Path) -> None:
    if not isinstance(actual, str) or actual.lower() != expected.lower():
        raise AssertionError(f"{source}: {label}={actual}, reviewed mainnet address is {expected}")


def main() -> int:
    validate_fixtures()
    lock = json.loads(LOCK_PATH.read_text())
    oneinch_address = str(lock["oneInch"]["address"])
    uniswap_address = str(lock["uniswap"]["address"])
    market_address = str(lock["uniswapMarket"]["address"])
    market_config_path = ROOT / "config" / "market-deploy-config.json"
    market_config = json.loads(market_config_path.read_text())["helpersMarket"]
    require_address("helpersMarket.uniswapRouter", market_config.get("uniswapRouter"), market_address, market_config_path)

    config_path = ROOT / "config" / "deploy-config.json"
    config = json.loads(config_path.read_text())
    helpers = config.get("helpers", {})
    require_address("helpers.oneInchRouter", helpers.get("oneInchRouter"), oneinch_address, config_path)
    require_address("helpers.uniswapRouter", helpers.get("uniswapRouter"), uniswap_address, config_path)

    for path in FORK_TESTS:
        text = path.read_text().lower()
        expected = oneinch_address if "oneinch" in path.name.lower() or path.name == "BasketRouterFork.t.sol" else uniswap_address
        if expected.lower() not in text:
            raise AssertionError(f"{path}: must exercise the reviewed router at {expected}")

    print(f"Reviewed router locks verified: 1inch {oneinch_address}, historical Uniswap {uniswap_address}, market V2.2.0 {market_address}")

    if "--check-upstream" in sys.argv[1:]:
        oneinch_version, upstream_oneinch = latest_oneinch_release(fetch_text(ONEINCH_RELEASES_URL))
        uniswap_version, upstream_uniswap = latest_uniswap_release(fetch_text(UNISWAP_RELEASES_URL))
        notices: list[str] = []
        if upstream_oneinch.lower() != oneinch_address.lower():
            notices.append(f"1inch upstream V{oneinch_version} is {upstream_oneinch}")
        if upstream_uniswap.lower() != market_address.lower():
            notices.append(f"Uniswap upstream V{uniswap_version} is {upstream_uniswap}")
        if notices:
            message = "ADVISORY UPSTREAM ROUTER REVIEW REQUIRED: " + "; ".join(notices)
            print(message)
            if os.environ.get("GITHUB_ACTIONS") == "true":
                print(f"::warning title=Advisory router update available::{message}")
            return 2
        else:
            print("Upstream router sources still match the reviewed lock.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
