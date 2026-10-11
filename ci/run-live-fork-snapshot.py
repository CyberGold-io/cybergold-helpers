#!/usr/bin/env python3
"""Run Helpers fork suites against one immutable, locally pinned live snapshot."""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from rpc_secret_sanitizer import sanitize_rpc_text


LOOPBACK_HOST = "127.0.0.1"
STARTUP_TIMEOUT_SECONDS = 60.0
PROCESS_STOP_TIMEOUT_SECONDS = 10.0


class RunnerInterrupted(RuntimeError):
    """Raised so signal-driven exits still execute process-group cleanup."""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--result", required=True, type=Path)
    return parser.parse_args()


def atomic_json_write(path: Path, document: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(
        json.dumps(document, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def reserve_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind((LOOPBACK_HOST, 0))
        return int(listener.getsockname()[1])


def rpc_request(url: str, method: str, params: list[Any], request_id: int) -> Any:
    payload = json.dumps(
        {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
    ).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=2.0) as response:
        document = json.loads(response.read().decode("utf-8"))
    if document.get("error") is not None:
        raise RuntimeError(f"{method} returned JSON-RPC error {document['error']!r}")
    if "result" not in document:
        raise RuntimeError(f"{method} response omitted result")
    return document["result"]


def wait_until_ready(process: subprocess.Popen[bytes], rpc_url: str) -> None:
    deadline = time.monotonic() + STARTUP_TIMEOUT_SECONDS
    last_error = "local Anvil did not answer"
    while time.monotonic() < deadline:
        status = process.poll()
        if status is not None:
            raise RuntimeError(f"local Anvil exited during startup with status {status}")
        try:
            chain_id = rpc_request(rpc_url, "eth_chainId", [], 1)
        except (OSError, ValueError, RuntimeError, urllib.error.URLError) as error:
            last_error = str(error)
        else:
            if chain_id != "0x1":
                raise RuntimeError(f"local fork is not Ethereum mainnet (chain ID {chain_id!r})")
            return
        time.sleep(0.1)
    raise RuntimeError(f"local Anvil startup timed out: {last_error}")


def resolve_snapshot_identity(rpc_url: str) -> tuple[int, str]:
    # Read the local fork head once, then bind every test and retained artifact to
    # that exact number/hash pair. No mutable `latest` value is retained.
    block_hex = rpc_request(rpc_url, "eth_blockNumber", [], 2)
    if not isinstance(block_hex, str) or not block_hex.startswith("0x"):
        raise RuntimeError(f"eth_blockNumber returned invalid value {block_hex!r}")
    block_number = int(block_hex, 16)
    if block_number <= 0:
        raise RuntimeError(f"resolved snapshot block number is invalid: {block_number}")
    block = rpc_request(rpc_url, "eth_getBlockByNumber", [block_hex, False], 3)
    if not isinstance(block, dict):
        raise RuntimeError("resolved snapshot block is unavailable")
    returned_number = block.get("number")
    block_hash = block.get("hash")
    if not isinstance(returned_number, str) or int(returned_number, 16) != block_number:
        raise RuntimeError("resolved snapshot block number changed during identity lookup")
    if (
        not isinstance(block_hash, str)
        or len(block_hash) != 66
        or not block_hash.startswith("0x")
        or any(character not in "0123456789abcdefABCDEF" for character in block_hash[2:])
        or int(block_hash, 16) == 0
    ):
        raise RuntimeError(f"resolved snapshot block hash is invalid: {block_hash!r}")
    return block_number, block_hash.lower()


def verify_snapshot_identity(rpc_url: str, block_number: int, block_hash: str) -> None:
    if rpc_request(rpc_url, "eth_chainId", [], 4) != "0x1":
        raise RuntimeError("local fork stopped reporting Ethereum mainnet after tests")
    block = rpc_request(rpc_url, "eth_getBlockByNumber", [hex(block_number), False], 5)
    if not isinstance(block, dict):
        raise RuntimeError("resolved snapshot block became unavailable after tests")
    returned_number = block.get("number")
    returned_hash = block.get("hash")
    if (
        not isinstance(returned_number, str)
        or int(returned_number, 16) != block_number
        or not isinstance(returned_hash, str)
        or returned_hash.lower() != block_hash
    ):
        raise RuntimeError("resolved snapshot block identity changed during fork tests")


def sanitize(text: str, upstream_url: str) -> str:
    return sanitize_rpc_text(
        text,
        upstream_url,
        url_replacement="<redacted-upstream-rpc-url>",
        credential_replacement="<redacted-upstream-rpc-credential>",
    )


def process_group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_for_process_group_exit(
    process_group: int,
    timeout: float,
    leader: subprocess.Popen[bytes],
) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        leader.poll()
        if not process_group_exists(process_group):
            return True
        time.sleep(0.05)
    leader.poll()
    return not process_group_exists(process_group)


def terminate_process_group(process: subprocess.Popen[bytes] | None) -> bool:
    if process is None:
        return True
    # start_new_session=True makes the child PID the stable process-group ID.
    # Keep using that ID even if the leader exits before cleanup so descendants
    # cannot survive as an orphaned Anvil/Forge subprocess.
    process_group = process.pid
    try:
        os.killpg(process_group, signal.SIGTERM)
    except ProcessLookupError:
        pass
    group_exited = wait_for_process_group_exit(
        process_group,
        PROCESS_STOP_TIMEOUT_SECONDS,
        process,
    )
    if not group_exited:
        try:
            os.killpg(process_group, signal.SIGKILL)
        except ProcessLookupError:
            pass
        group_exited = wait_for_process_group_exit(
            process_group,
            PROCESS_STOP_TIMEOUT_SECONDS,
            process,
        )
    try:
        process.wait(timeout=1.0)
    except subprocess.TimeoutExpired:
        return False
    return group_exited and process.poll() is not None


def read_log(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return ""


def install_signal_handlers() -> None:
    def interrupt(signum: int, _frame: Any) -> None:
        raise RunnerInterrupted(f"received signal {signum}")

    for signal_name in ("SIGINT", "SIGTERM", "SIGHUP"):
        candidate = getattr(signal, signal_name, None)
        if candidate is not None:
            signal.signal(candidate, interrupt)


def main() -> int:
    args = parse_args()
    root = args.root.resolve()
    upstream_url = os.environ.get("MAINNET_RPC_URL", "")
    if not upstream_url:
        print("ERROR: MAINNET_RPC_URL is required by the live snapshot runner.", file=sys.stderr)
        return 2

    args.log.parent.mkdir(parents=True, exist_ok=True)
    args.result.parent.mkdir(parents=True, exist_ok=True)
    install_signal_handlers()

    anvil_process: subprocess.Popen[bytes] | None = None
    forge_process: subprocess.Popen[bytes] | None = None
    block_number: int | None = None
    block_hash: str | None = None
    forge_exit_code = 1
    failure_reason: str | None = None
    anvil_cleanup_complete = False
    forge_cleanup_complete = False

    with tempfile.TemporaryDirectory(prefix="helpers-live-fork-") as temporary:
        temporary_path = Path(temporary)
        raw_anvil_log = temporary_path / "anvil.raw.log"
        raw_forge_log = temporary_path / "forge.raw.log"

        try:
            port = reserve_loopback_port()
            local_rpc_url = f"http://{LOOPBACK_HOST}:{port}"
            with raw_anvil_log.open("wb") as anvil_stream:
                anvil_process = subprocess.Popen(
                    [
                        "anvil",
                        "--host",
                        LOOPBACK_HOST,
                        "--port",
                        str(port),
                        "--fork-url",
                        upstream_url,
                        "--silent",
                    ],
                    cwd=root,
                    stdout=anvil_stream,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
            wait_until_ready(anvil_process, local_rpc_url)
            block_number, block_hash = resolve_snapshot_identity(local_rpc_url)

            forge_environment = os.environ.copy()
            # Two fork suites create their own Foundry fork from these variables.
            # Give every test only the private loopback endpoint and the one
            # resolved immutable block; the protected upstream URL never enters
            # the Forge environment or command line.
            forge_environment["MAINNET_RPC_URL"] = local_rpc_url
            forge_environment["MAINNET_FORK_BLOCK"] = str(block_number)
            with raw_forge_log.open("wb") as forge_stream:
                forge_process = subprocess.Popen(
                    [
                        "forge",
                        "test",
                        "--root",
                        str(root),
                        "--match-path",
                        "test/*Fork*.t.sol",
                        "--fork-url",
                        local_rpc_url,
                        "--fork-block-number",
                        str(block_number),
                    ],
                    cwd=root,
                    env=forge_environment,
                    stdout=forge_stream,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                forge_exit_code = int(forge_process.wait())
            if forge_exit_code == 0:
                verify_snapshot_identity(local_rpc_url, block_number, block_hash)
        except (OSError, ValueError, RuntimeError, RunnerInterrupted) as error:
            failure_reason = str(error)
            if forge_process is not None and forge_process.poll() is not None:
                forge_exit_code = int(forge_process.returncode)
        finally:
            forge_cleanup_complete = terminate_process_group(forge_process)
            anvil_cleanup_complete = terminate_process_group(anvil_process)

        if not forge_cleanup_complete or not anvil_cleanup_complete:
            failure_reason = "fork process-group cleanup did not complete"
            forge_exit_code = 1
        elif failure_reason is not None:
            forge_exit_code = forge_exit_code or 1

        lines = [
            "Helpers release fork runner",
            "forkMode=live-latest-snapshot",
            f"resolvedBlockNumber={block_number if block_number is not None else 'unavailable'}",
            f"resolvedBlockHash={block_hash if block_hash is not None else 'unavailable'}",
            f"anvilProcessGroupCleanup={'complete' if anvil_cleanup_complete else 'failed'}",
            f"forgeProcessGroupCleanup={'complete' if forge_cleanup_complete else 'failed'}",
        ]
        if failure_reason is not None:
            lines.append(f"runnerFailure={failure_reason}")
        lines.extend(
            (
                "--- local Anvil output ---",
                read_log(raw_anvil_log),
                "--- Forge output ---",
                read_log(raw_forge_log),
            )
        )
        args.log.write_text(
            sanitize("\n".join(lines).rstrip() + "\n", upstream_url),
            encoding="utf-8",
        )

    atomic_json_write(
        args.result,
        {
            "schemaVersion": 1,
            "forkMode": "live-latest-snapshot",
            "forkBlock": block_number,
            "forkBlockHash": block_hash,
            "forgeExitCode": forge_exit_code,
            "anvilProcessGroupCleanupComplete": anvil_cleanup_complete,
            "forgeProcessGroupCleanupComplete": forge_cleanup_complete,
            "runnerFailure": (
                sanitize(failure_reason, upstream_url)
                if failure_reason is not None
                else None
            ),
        },
    )
    return forge_exit_code


if __name__ == "__main__":
    raise SystemExit(main())
