#!/usr/bin/env python3
"""Resolve and validate one exact Ethereum mainnet RPC block identity."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
import urllib.request
from pathlib import Path
from typing import Any

USER_AGENT = (
    "CyberGold-Helpers-RPC-Identity/1.0 "
    "(+https://github.com/CyberGold-io/cybergold-helpers)"
)


def rpc_request(url: str, method: str, params: list[Any], request_id: int) -> Any:
    payload = json.dumps(
        {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
    ).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10.0) as response:
        document = json.loads(response.read().decode("utf-8"))
    if document.get("error") is not None:
        raise RuntimeError(f"{method} returned JSON-RPC error {document['error']!r}")
    if "result" not in document:
        raise RuntimeError(f"{method} response omitted result")
    return document["result"]


def resolve_identity(url: str, block_number: int) -> dict[str, Any]:
    chain_id = rpc_request(url, "eth_chainId", [], 1)
    if chain_id != "0x1":
        raise RuntimeError(f"RPC is not Ethereum mainnet (chain ID {chain_id!r})")
    block = rpc_request(url, "eth_getBlockByNumber", [hex(block_number), False], 2)
    if not isinstance(block, dict):
        raise RuntimeError(f"mainnet block {block_number} is unavailable")
    returned_number = block.get("number")
    block_hash = block.get("hash")
    if (
        not isinstance(returned_number, str)
        or not returned_number.startswith("0x")
        or int(returned_number, 16) != block_number
    ):
        raise RuntimeError("RPC returned a different block number")
    if (
        not isinstance(block_hash, str)
        or len(block_hash) != 66
        or not block_hash.startswith("0x")
        or any(character not in "0123456789abcdefABCDEF" for character in block_hash[2:])
        or int(block_hash, 16) == 0
    ):
        raise RuntimeError(f"RPC returned an invalid block hash {block_hash!r}")
    return {
        "schemaVersion": 1,
        "chainId": 1,
        "forkBlock": block_number,
        "forkBlockHash": block_hash.lower(),
    }


def atomic_write(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    ) as stream:
        temporary = Path(stream.name)
        json.dump(document, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--block-number", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--expected-hash")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.block_number <= 0:
        raise SystemExit("ERROR: block number must be positive")
    url = os.environ.get("MAINNET_RPC_URL", "")
    if not url:
        raise SystemExit("ERROR: MAINNET_RPC_URL is required")
    identity = resolve_identity(url, args.block_number)
    if args.expected_hash is not None and identity["forkBlockHash"] != args.expected_hash.lower():
        raise SystemExit(
            "ERROR: RPC block identity changed "
            f"(expected {args.expected_hash.lower()}, got {identity['forkBlockHash']})"
        )
    atomic_write(args.output, identity)
    print(
        "Ethereum mainnet RPC block identity verified: "
        f"{identity['forkBlock']} @ {identity['forkBlockHash']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
