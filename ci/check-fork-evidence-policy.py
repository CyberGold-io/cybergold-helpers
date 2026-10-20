#!/usr/bin/env python3
"""Prove development and release fork-evidence modes fail with the intended semantics."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Iterator

sys.dont_write_bytecode = True
from rpc_secret_sanitizer import sanitize_rpc_text


ROOT = Path(__file__).resolve().parents[1]
FORK_GATE = ROOT / "ci" / "check-fork-tests.sh"
WARNING = "WARNING: HELPERS FORK EVIDENCE UNAVAILABLE"
NOT_PASS = "fork tests were NOT RUN; this is NOT A PASS"
GITHUB_WARNING = "::warning title=Helpers fork evidence unavailable::"
RELEASE_FAILURE = "release fork evidence is mandatory and fails closed"
PINNED_BLOCK = 25609006
EXPECTED_RPC_IDENTITY_USER_AGENT = (
    "CyberGold-Helpers-RPC-Identity/1.0 "
    "(+https://github.com/CyberGold-io/cybergold-helpers)"
)


def run_gate(
    gate: Path,
    *,
    cwd: Path,
    release: bool,
    rpc_url: str | None,
    expected_commit: str | None = None,
    github_actions: bool = False,
    path: str | None = None,
    evidence_dir: Path | None = None,
    fork_mode: str | None = None,
    mainnet_fork_block: str | None = None,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.pop("MAINNET_RPC_BEARER", None)
    # Authenticated cases select their own wrapper below. An outer wrapper's
    # target must not make the standalone fake Anvil contact a fixture URL.
    env.pop("CYBERGOLD_RPC_TARGET", None)
    if rpc_url is None:
        env.pop("MAINNET_RPC_URL", None)
    else:
        env["MAINNET_RPC_URL"] = rpc_url
    if expected_commit is None:
        env.pop("EXPECTED_HELPERS_COMMIT", None)
    else:
        env["EXPECTED_HELPERS_COMMIT"] = expected_commit
    if github_actions:
        env["GITHUB_ACTIONS"] = "true"
    else:
        env.pop("GITHUB_ACTIONS", None)
    if path is not None:
        env["PATH"] = path
    if evidence_dir is not None:
        env["HELPERS_FORK_EVIDENCE_OUT"] = str(evidence_dir)
    if fork_mode is None:
        env.pop("HELPERS_RELEASE_FORK_MODE", None)
    else:
        env["HELPERS_RELEASE_FORK_MODE"] = fork_mode
    if mainnet_fork_block is None:
        env.pop("MAINNET_FORK_BLOCK", None)
    else:
        env["MAINNET_FORK_BLOCK"] = mainnet_fork_block
    if extra_env is not None:
        env.update(extra_env)
    command = ["bash", str(gate)]
    if release:
        command.append("--release-evidence")
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        check=False,
        capture_output=True,
        text=True,
    )


def assert_unavailable_warning(result: subprocess.CompletedProcess[str], *, github_actions: bool) -> None:
    if result.returncode != 0:
        raise ValueError(f"missing-RPC fork gate returned {result.returncode}")
    combined = f"{result.stdout}\n{result.stderr}"
    if WARNING not in combined or NOT_PASS not in combined:
        raise ValueError("missing-RPC fork gate did not emit the required not-run/not-pass warning")
    if github_actions and GITHUB_WARNING not in combined:
        raise ValueError("missing-RPC GitHub gate did not emit an Actions warning annotation")


def initialize_fixture(temp_root: Path) -> tuple[Path, str, Path]:
    (temp_root / "ci" / "helpers").mkdir(parents=True)
    shutil.copy2(FORK_GATE, temp_root / "ci" / "check-fork-tests.sh")
    shutil.copy2(
        ROOT / "ci" / "run-live-fork-snapshot.py",
        temp_root / "ci" / "run-live-fork-snapshot.py",
    )
    shutil.copy2(
        ROOT / "ci" / "rpc_secret_sanitizer.py",
        temp_root / "ci" / "rpc_secret_sanitizer.py",
    )
    shutil.copy2(
        ROOT / "ci" / "rpc_block_identity.py",
        temp_root / "ci" / "rpc_block_identity.py",
    )
    shutil.copy2(ROOT / "ci" / "helpers" / "bootstrap.sh", temp_root / "ci" / "helpers" / "bootstrap.sh")
    (temp_root / "ci" / "tracked-state.txt").write_text("clean\n", encoding="utf-8")
    runner = temp_root / "lib/cybergold-protocol/ci/helpers/with-authenticated-rpc.py"
    runner.parent.mkdir(parents=True)
    shutil.copy2(ROOT / "lib/cybergold-protocol/ci/helpers/with-authenticated-rpc.py", runner)
    fake_bin = temp_root.parent / "fake-bin"
    fake_bin.mkdir()
    fake_forge = fake_bin / "forge"
    fake_forge.write_text(
        "#!/usr/bin/env bash\n"
        'echo "fake forge invoked for $*"\n'
        'echo "rpc=${MAINNET_RPC_URL:-<unset>}"\n'
        'echo "forkBlock=${MAINNET_FORK_BLOCK:-<unset>}"\n'
        'if [ "${FAKE_FORGE_EMIT_FRAGMENT_SECRETS:-}" = "1" ]; then\n'
        '  echo "provider path credential: archive-path-secret"\n'
        '  echo "provider query credential: query-token-secret"\n'
        "fi\n"
        'if [ "${FAKE_FORGE_EXIT_CODE:-0}" -eq 0 ]; then\n'
        '  if [ "${FAKE_FORGE_OMIT_SUITE:-}" != "basket" ]; then\n'
        '    echo "Ran 1 test for test/BasketRouterFork.t.sol:BasketRouterForkTest"\n'
        "  fi\n"
        '  if [ "${FAKE_FORGE_OMIT_SUITE:-}" != "basket-uniswap" ]; then\n'
        '    echo "Ran 2 tests for test/BasketRouterUniswapFork.t.sol:BasketRouterUniswapForkTest"\n'
        "  fi\n"
        '  if [ "${FAKE_FORGE_OMIT_SUITE:-}" != "one-inch" ]; then\n'
        '    echo "Ran 2 tests for test/OneInchFork.t.sol:OneInchForkTest"\n'
        "  fi\n"
        '  if [ "${FAKE_FORGE_OMIT_SUITE:-}" != "uniswap-universal" ]; then\n'
        '    echo "Ran 4 tests for test/UniswapUniversalFork.t.sol:UniswapUniversalForkTest"\n'
        "  fi\n"
        '  if [ "${FAKE_FORGE_EXTRA_SUITE:-}" = "1" ]; then\n'
        '    echo "Ran 1 test for test/UnexpectedFork.t.sol:UnexpectedForkTest"\n'
        "  fi\n"
        "fi\n"
        'if [ -n "${FAKE_FORGE_DIRTY_FILE:-}" ]; then\n'
        '  printf "mutated\\n" >> "${FAKE_FORGE_DIRTY_FILE}"\n'
        "fi\n"
        'if [ "${FAKE_FORGE_MOVE_HEAD:-}" = "1" ]; then\n'
        '  printf "committed mutation\\n" >> ci/tracked-state.txt\n'
        "  git add ci/tracked-state.txt\n"
        '  git -c user.name="Helpers CI" -c user.email="helpers-ci@example.invalid" '
        'commit -qm "mutate candidate during fork run"\n'
        "fi\n"
        'exit "${FAKE_FORGE_EXIT_CODE:-0}"\n',
        encoding="utf-8",
    )
    fake_forge.chmod(0o755)
    fake_anvil = fake_bin / "anvil"
    fake_anvil.write_text(
        """#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

parser = argparse.ArgumentParser(add_help=False)
parser.add_argument("--host", required=True)
parser.add_argument("--port", required=True, type=int)
parser.add_argument("--fork-url")
arguments, _ = parser.parse_known_args()
print("fake anvil invoked for " + " ".join(sys.argv[1:]), flush=True)
start_marker = os.environ.get("FAKE_ANVIL_START_MARKER")
if start_marker:
    Path(start_marker).write_text("started\\n", encoding="utf-8")
child_stop_marker = os.environ.get("FAKE_ANVIL_CHILD_STOP_MARKER")
if child_stop_marker:
    subprocess.Popen(
        [
            sys.executable,
            "-c",
            (
                "import signal,time;"
                "from pathlib import Path;"
                f"path=Path({child_stop_marker!r});"
                "signal.signal(signal.SIGTERM,lambda *_:(path.write_text('stopped\\\\n'),exit(0)));"
                "time.sleep(300)"
            ),
        ]
    )

class Handler(BaseHTTPRequestHandler):
    block_requests = 0

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length))
        method = request["method"]
        if os.environ.get("CYBERGOLD_RPC_TARGET") == "mainnet":
            probe = urllib.request.Request(arguments.fork_url, data=json.dumps({"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}).encode(), headers={"Content-Type":"application/json"})
            with urllib.request.urlopen(probe, timeout=3) as upstream:
                assert json.load(upstream)["result"] == "0x1"
        if method == "eth_chainId":
            result = os.environ.get("FAKE_ANVIL_CHAIN_ID", "0x1")
        elif method == "eth_blockNumber":
            result = "0x18cba80"
        elif method == "eth_getBlockByNumber":
            Handler.block_requests += 1
            block_hash = "0x" + "ab" * 32
            if (
                os.environ.get("FAKE_ANVIL_CHANGE_HASH_AFTER_FIRST") == "1"
                and Handler.block_requests > 1
            ):
                block_hash = "0x" + "ef" * 32
            result = {"number": "0x18cba80", "hash": block_hash}
        else:
            result = None
        payload = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_):
        return

HTTPServer((arguments.host, arguments.port), Handler).serve_forever()
""",
        encoding="utf-8",
    )
    fake_anvil.chmod(0o755)
    subprocess.run(["git", "init", "-q"], cwd=temp_root, check=True)
    subprocess.run(["git", "add", "ci", "lib"], cwd=temp_root, check=True)
    subprocess.run(
        [
            "git",
            "-c",
            "user.name=Helpers CI",
            "-c",
            "user.email=helpers-ci@example.invalid",
            "commit",
            "-qm",
            "fork evidence fixture",
        ],
        cwd=temp_root,
        check=True,
    )
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=temp_root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    return temp_root / "ci" / "check-fork-tests.sh", commit, fake_bin


class FixtureRpcHandler(BaseHTTPRequestHandler):
    server: "FixtureRpcServer"

    def do_POST(self) -> None:
        self.server.user_agents.append(self.headers.get("User-Agent", ""))
        self.server.authorizations.append(self.headers.get("Authorization", ""))
        length = int(self.headers.get("Content-Length", "0"))
        request = json.loads(self.rfile.read(length))
        method = request["method"]
        if method == "eth_chainId":
            result = self.server.chain_id
        elif method == "eth_getBlockByNumber":
            self.server.block_requests += 1
            block_hash = self.server.block_hash
            if self.server.change_hash_after_first and self.server.block_requests > 1:
                block_hash = "0x" + "ef" * 32
            result = {"number": hex(PINNED_BLOCK), "hash": block_hash}
        else:
            result = None
        payload = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}).encode()
        self.send_response(self.server.http_status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_: object) -> None:
        return


class FixtureRpcServer(ThreadingHTTPServer):
    http_status = 200
    chain_id = "0x1"
    block_hash = "0x" + "cd" * 32
    block_requests = 0
    change_hash_after_first = False
    user_agents: list[str]


@contextmanager
def fixture_rpc_server() -> Iterator[tuple[FixtureRpcServer, str]]:
    server = FixtureRpcServer(("127.0.0.1", 0), FixtureRpcHandler)
    server.user_agents = []
    server.authorizations = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address
    url = (
        f"http://{host}:{port}/v2/archive-path-secret"
        "?token=query-token-secret"
    )
    try:
        yield server, url
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5.0)


def wait_for_marker(path: Path) -> None:
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.05)
    raise ValueError(f"process-group child cleanup marker was not written: {path}")


def assert_release_modes() -> None:
    with (
        tempfile.TemporaryDirectory(prefix="helpers-fork-policy-") as temporary,
        fixture_rpc_server() as (pinned_server, pinned_rpc_url),
    ):
        temporary_path = Path(temporary)
        fixture_root = temporary_path / "fixture"
        fixture_root.mkdir()
        gate, commit, fake_bin = initialize_fixture(fixture_root)
        evidence_dir = temporary_path / "evidence"
        failing_env_path = f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}"

        missing_commit = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url=pinned_rpc_url,
            expected_commit=None,
            path=failing_env_path,
            evidence_dir=temporary_path / "missing-commit-evidence",
        )
        if (
            missing_commit.returncode == 0
            or "EXPECTED_HELPERS_COMMIT is required" not in f"{missing_commit.stdout}\n{missing_commit.stderr}"
        ):
            raise ValueError("release mode accepted a missing exact commit authority")

        mismatched_commit = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url=pinned_rpc_url,
            expected_commit="0" * 40,
            path=failing_env_path,
            evidence_dir=temporary_path / "mismatched-commit-evidence",
        )
        if (
            mismatched_commit.returncode == 0
            or "release fork evidence commit mismatch"
            not in f"{mismatched_commit.stdout}\n{mismatched_commit.stderr}"
        ):
            raise ValueError("release mode accepted a mismatched exact commit authority")

        invalid_mode = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url=pinned_rpc_url,
            expected_commit=commit,
            path=failing_env_path,
            evidence_dir=temporary_path / "invalid-mode-evidence",
            fork_mode="automatic-fallback",
        )
        if (
            invalid_mode.returncode == 0
            or "must be pinned-history or live-latest-snapshot"
            not in f"{invalid_mode.stdout}\n{invalid_mode.stderr}"
        ):
            raise ValueError("release mode accepted an unapproved fork authority")

        dirty_marker = fixture_root / "untracked-release-state.txt"
        dirty_marker.write_text("dirty\n", encoding="utf-8")
        dirty_checkout = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url=pinned_rpc_url,
            expected_commit=commit,
            path=failing_env_path,
            evidence_dir=temporary_path / "dirty-checkout-evidence",
        )
        dirty_marker.unlink()
        if (
            dirty_checkout.returncode == 0
            or "requires a clean exact checkout"
            not in f"{dirty_checkout.stdout}\n{dirty_checkout.stderr}"
        ):
            raise ValueError("release mode accepted a dirty candidate checkout")

        no_rpc = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url=None,
            expected_commit=commit,
            evidence_dir=evidence_dir,
        )
        combined = f"{no_rpc.stdout}\n{no_rpc.stderr}"
        if no_rpc.returncode == 0 or RELEASE_FAILURE not in combined:
            raise ValueError("release mode did not fail closed with explicit status when RPC was absent")
        unavailable = json.loads((evidence_dir / "fork-evidence.json").read_text(encoding="utf-8"))
        if (
            unavailable["status"] != "not-run"
            or unavailable["sourceCommit"] != commit
            or unavailable["forkMode"] != "pinned-history"
        ):
            raise ValueError("release missing-RPC evidence did not bind the not-run result to the exact commit")

        shutil.rmtree(evidence_dir)
        unexpected_anvil_marker = temporary_path / "unexpected-anvil-start"
        failed_rpc = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url=pinned_rpc_url,
            expected_commit=commit,
            path=failing_env_path,
            evidence_dir=evidence_dir,
            extra_env={
                "FAKE_FORGE_EXIT_CODE": "23",
                "FAKE_FORGE_EMIT_FRAGMENT_SECRETS": "1",
                "FAKE_ANVIL_START_MARKER": str(unexpected_anvil_marker),
            },
        )
        if failed_rpc.returncode != 23:
            raise ValueError(f"release mode swallowed a failing fork runner ({failed_rpc.returncode})")
        if unexpected_anvil_marker.exists():
            raise ValueError("failed pinned-history mode silently fell back to a live snapshot")
        failed = json.loads((evidence_dir / "fork-evidence.json").read_text(encoding="utf-8"))
        if (
            failed["status"] != "failed"
            or failed["forgeExitCode"] != 23
            or failed["forkBlock"] != PINNED_BLOCK
            or failed["forkBlockHash"] != "0x" + "cd" * 32
            or failed["forkMode"] != "pinned-history"
            or failed["sourceCommit"] != commit
        ):
            raise ValueError("failed release evidence did not retain exact commit/block/failure identity")
        sanitized_log = (evidence_dir / "forge-test.sanitized.log").read_text(encoding="utf-8")
        if (
            "credential.invalid" in sanitized_log
            or "archive-path-secret" in sanitized_log
            or "query-token-secret" in sanitized_log
            or "<redacted-rpc-url>" not in sanitized_log
            or "<redacted-rpc-credential>" not in sanitized_log
        ):
            raise ValueError("retained release diagnostics exposed the RPC URL or a credential fragment")

        shutil.rmtree(evidence_dir)
        passed_rpc = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url=pinned_rpc_url,
            expected_commit=commit,
            path=failing_env_path,
            evidence_dir=evidence_dir,
        )
        if passed_rpc.returncode != 0:
            raise ValueError(f"release success fixture unexpectedly failed ({passed_rpc.returncode})")
        if not pinned_server.user_agents or any(
            value != EXPECTED_RPC_IDENTITY_USER_AGENT
            for value in pinned_server.user_agents
        ):
            raise ValueError(
                "RPC block-identity requests omitted the stable non-secret User-Agent"
            )
        passed = json.loads((evidence_dir / "fork-evidence.json").read_text(encoding="utf-8"))
        if (
            passed["status"] != "passed"
            or passed["sanitizedLogSha256"] is None
            or len(passed["expectedSuites"]) != 4
            or passed["expectedTestCount"] != 9
            or passed["observedTestCount"] != 9
            or passed["suiteCompleteness"] is not True
            or passed["forkBlockHash"] != "0x" + "cd" * 32
        ):
            raise ValueError("successful release evidence did not retain a hashed sanitized log")
        if (fixture_root / "ci" / "__pycache__").exists():
            raise ValueError("release evidence created Python bytecode inside the exact checkout")

        shutil.rmtree(evidence_dir)
        pinned_server.chain_id = "0x89"
        wrong_pinned_chain = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url=pinned_rpc_url,
            expected_commit=commit,
            path=failing_env_path,
            evidence_dir=evidence_dir,
        )
        pinned_server.chain_id = "0x1"
        if wrong_pinned_chain.returncode == 0:
            raise ValueError("pinned-history mode accepted a non-mainnet RPC")

        shutil.rmtree(evidence_dir)
        pinned_server.block_requests = 0
        pinned_server.change_hash_after_first = True
        changed_pinned_identity = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url=pinned_rpc_url,
            expected_commit=commit,
            path=failing_env_path,
            evidence_dir=evidence_dir,
        )
        pinned_server.change_hash_after_first = False
        pinned_server.block_requests = 0
        if changed_pinned_identity.returncode == 0:
            raise ValueError("pinned-history mode accepted a changed post-test block identity")

        shutil.rmtree(evidence_dir)
        dirty_tracked_file = fixture_root / "ci" / "tracked-state.txt"
        mutated_checkout = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url=pinned_rpc_url,
            expected_commit=commit,
            path=failing_env_path,
            evidence_dir=evidence_dir,
            extra_env={"FAKE_FORGE_DIRTY_FILE": str(dirty_tracked_file)},
        )
        dirty_tracked_file.write_text("clean\n", encoding="utf-8")
        if (
            mutated_checkout.returncode == 0
            or "changed the exact candidate checkout"
            not in f"{mutated_checkout.stdout}\n{mutated_checkout.stderr}"
        ):
            raise ValueError("release mode accepted a checkout mutated during fork execution")

        rejected_override = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url="https://credential.invalid/live?token=secret-value",
            expected_commit=commit,
            path=failing_env_path,
            evidence_dir=temporary_path / "rejected-override-evidence",
            fork_mode="live-latest-snapshot",
            mainnet_fork_block=str(PINNED_BLOCK),
        )
        if rejected_override.returncode == 0 or "MAINNET_FORK_BLOCK must be unset" not in (
            f"{rejected_override.stdout}\n{rejected_override.stderr}"
        ):
            raise ValueError("live snapshot mode accepted a caller-supplied mutable block authority")

        wrong_chain_evidence = temporary_path / "wrong-chain-evidence"
        wrong_chain = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url="https://credential.invalid/live",
            expected_commit=commit,
            path=failing_env_path,
            evidence_dir=wrong_chain_evidence,
            fork_mode="live-latest-snapshot",
            extra_env={"FAKE_ANVIL_CHAIN_ID": "0x89"},
        )
        if wrong_chain.returncode == 0:
            raise ValueError("live snapshot mode accepted a non-mainnet upstream")
        wrong_chain_document = json.loads(
            (wrong_chain_evidence / "fork-evidence.json").read_text(encoding="utf-8")
        )
        if wrong_chain_document["status"] != "failed" or wrong_chain_document["forkBlock"] is not None:
            raise ValueError("wrong-chain live snapshot evidence did not fail before block resolution")

        shutil.rmtree(evidence_dir)
        child_stop_marker = temporary_path / "live-anvil-child-stopped"
        live_rpc = (
            "https://credential.invalid/v2/archive-path-secret"
            "?token=query-token-secret"
        )
        passed_live = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url=live_rpc,
            expected_commit=commit,
            path=failing_env_path,
            evidence_dir=evidence_dir,
            fork_mode="live-latest-snapshot",
            extra_env={
                "FAKE_ANVIL_CHILD_STOP_MARKER": str(child_stop_marker),
                "FAKE_FORGE_EMIT_FRAGMENT_SECRETS": "1",
            },
        )
        if passed_live.returncode != 0:
            raise ValueError(
                "live snapshot success fixture unexpectedly failed "
                f"({passed_live.returncode}): {passed_live.stderr}"
            )
        wait_for_marker(child_stop_marker)
        live = json.loads((evidence_dir / "fork-evidence.json").read_text(encoding="utf-8"))
        if (
            live["status"] != "passed"
            or live["forkMode"] != "live-latest-snapshot"
            or live["blockAuthority"] != "resolved-local-live-snapshot"
            or live["sourceCommit"] != commit
            or live["forkBlock"] != int("18cba80", 16)
            or live["forkBlockHash"] != "0x" + "ab" * 32
            or live["observedTestCount"] != 9
            or live["suiteCompleteness"] is not True
            or live["sanitizedLogSha256"] is None
            or live["processGroupCleanup"] != {"anvil": True, "forge": True}
        ):
            raise ValueError("live snapshot evidence did not retain exact immutable identity/completeness")
        live_log = (evidence_dir / "forge-test.sanitized.log").read_text(encoding="utf-8")
        if (
            live_rpc in live_log
            or "archive-path-secret" in live_log
            or "query-token-secret" in live_log
        ):
            raise ValueError("live snapshot evidence exposed the protected upstream RPC URL")
        if "<redacted-upstream-rpc-url>" not in live_log:
            raise ValueError("live snapshot sanitizer fixture did not exercise upstream URL redaction")
        if "rpc=http://127.0.0.1:" not in live_log or "forkBlock=26000000" not in live_log:
            raise ValueError("live snapshot Forge child did not receive the exact private snapshot authority")
        if "anvilProcessGroupCleanup=complete" not in live_log:
            raise ValueError("live snapshot evidence did not record successful process-group cleanup")
        anvil_log = live_log.split("--- local Anvil output ---", 1)[1].split(
            "--- Forge output ---", 1
        )[0]
        forge_log = live_log.split("--- Forge output ---", 1)[1]
        if "--fork-block-number" in anvil_log:
            raise ValueError("live Anvil startup incorrectly requested historical upstream state")
        if f"--fork-block-number {int('18cba80', 16)}" not in forge_log:
            raise ValueError("Forge was not pinned to the one resolved local snapshot block")
        if hashlib.sha256(live_log.encode("utf-8")).hexdigest() != live["sanitizedLogSha256"]:
            raise ValueError("live snapshot evidence log digest does not match the retained log")

        shutil.rmtree(evidence_dir)
        partial_live = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url=live_rpc,
            expected_commit=commit,
            path=failing_env_path,
            evidence_dir=evidence_dir,
            fork_mode="live-latest-snapshot",
            extra_env={"FAKE_FORGE_OMIT_SUITE": "uniswap-universal"},
        )
        if partial_live.returncode == 0:
            raise ValueError("live snapshot mode accepted a partial 3-suite/5-test Forge result")
        partial = json.loads((evidence_dir / "fork-evidence.json").read_text(encoding="utf-8"))
        if (
            partial["status"] != "failed"
            or partial["suiteCompleteness"] is not False
            or partial["observedTestCount"] != 5
        ):
            raise ValueError("partial live snapshot evidence did not retain suite incompleteness")

        shutil.rmtree(evidence_dir)
        extra_live = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url=live_rpc,
            expected_commit=commit,
            path=failing_env_path,
            evidence_dir=evidence_dir,
            fork_mode="live-latest-snapshot",
            extra_env={"FAKE_FORGE_EXTRA_SUITE": "1"},
        )
        if extra_live.returncode == 0:
            raise ValueError("live snapshot mode accepted an unexpected fifth fork suite")
        extra = json.loads((evidence_dir / "fork-evidence.json").read_text(encoding="utf-8"))
        if (
            extra["status"] != "failed"
            or extra["suiteCompleteness"] is not False
            or extra["observedTestCount"] != 10
            or "test/UnexpectedFork.t.sol:UnexpectedForkTest"
            not in extra["observedSuiteTestCounts"]
        ):
            raise ValueError("extra-suite live snapshot evidence did not retain exact incompleteness")

        shutil.rmtree(evidence_dir)
        changed_live_identity = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url=live_rpc,
            expected_commit=commit,
            path=failing_env_path,
            evidence_dir=evidence_dir,
            fork_mode="live-latest-snapshot",
            extra_env={"FAKE_ANVIL_CHANGE_HASH_AFTER_FIRST": "1"},
        )
        if changed_live_identity.returncode == 0:
            raise ValueError("live snapshot mode accepted a changed post-test block identity")

        shutil.rmtree(evidence_dir)
        moved_head = run_gate(
            gate,
            cwd=fixture_root,
            release=True,
            rpc_url=live_rpc,
            expected_commit=commit,
            path=failing_env_path,
            evidence_dir=evidence_dir,
            fork_mode="live-latest-snapshot",
            extra_env={"FAKE_FORGE_MOVE_HEAD": "1"},
        )
        if (
            moved_head.returncode == 0
            or "changed the candidate commit"
            not in f"{moved_head.stdout}\n{moved_head.stderr}"
        ):
            raise ValueError("release mode accepted a clean checkout whose HEAD moved during execution")


def assert_authenticated_release_modes() -> None:
    with tempfile.TemporaryDirectory(prefix="helpers-auth-fork-policy-") as temporary, fixture_rpc_server() as (server, url):
        root = Path(temporary)
        fixture = root / "fixture"
        fixture.mkdir()
        gate, commit, fake_bin = initialize_fixture(fixture)
        bearer = "synthetic-ci-bearer"
        for mode in ("pinned-history", "live-latest-snapshot"):
            for exit_code in (0, 23):
                evidence = root / f"{mode}-{exit_code}"
                server.authorizations.clear()
                result = run_gate(
                    gate, cwd=fixture, release=True, rpc_url=url,
                    expected_commit=commit, path=f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}",
                    evidence_dir=evidence, fork_mode=mode,
                    extra_env={"MAINNET_RPC_BEARER": bearer, "FAKE_FORGE_EXIT_CODE": str(exit_code)},
                )
                if result.returncode != exit_code:
                    raise ValueError(f"authenticated {mode} lost fork exit status: {result.returncode}: {result.stderr}")
                document = json.loads((evidence / "fork-evidence.json").read_text())
                if document["status"] != ("passed" if exit_code == 0 else "failed") or document["sourceCommit"] != commit:
                    raise ValueError(f"authenticated {mode} lost exact source/outcome evidence")
                retained = (evidence / "forge-test.sanitized.log").read_text() + result.stdout + result.stderr
                if bearer in retained or url in retained:
                    raise ValueError(f"authenticated {mode} exposed upstream credentials")
                if not server.authorizations or any(value != "Bearer " + bearer for value in server.authorizations):
                    raise ValueError(f"authenticated {mode} omitted the upstream bearer")
                if mode == "pinned-history" and len(server.authorizations) < (5 if exit_code == 0 else 3):
                    raise ValueError("authenticated pinned pre/post checks did not share the adapter lifetime")
                if mode == "live-latest-snapshot" and not all(document["processGroupCleanup"].values()):
                    raise ValueError("authenticated snapshot did not stop its owned processes")


        server.http_status = 403
        for mode in ("pinned-history", "live-latest-snapshot"):
            evidence = root / f"{mode}-auth-failure"
            # A failed new attempt must replace an earlier passing document.
            evidence.mkdir()
            (evidence / "fork-evidence.json").write_text('{"status":"passed"}')
            result = run_gate(
                gate, cwd=fixture, release=True, rpc_url=url,
                expected_commit=commit, path=f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}",
                evidence_dir=evidence, fork_mode=mode,
                extra_env={"MAINNET_RPC_BEARER": bearer},
            )
            document = json.loads((evidence / "fork-evidence.json").read_text())
            if result.returncode == 0 or document["status"] != "failed" or document["sourceCommit"] != commit:
                raise ValueError("authenticated startup failure lost failed exact-source evidence")
            if document["observedTestCount"] != 0 or document["suiteCompleteness"]:
                raise ValueError("authentication failure claimed executed fork coverage")
            if "HTTP 403" not in result.stderr or bearer in result.stdout + result.stderr + json.dumps(document):
                raise ValueError("authentication failure lost its safe HTTP diagnostic or exposed a bearer")
            if "fake forge invoked" in result.stdout:
                raise ValueError("authentication failure started Forge")


def assert_short_explicit_credentials_are_redacted() -> None:
    url = "https://x:y@rpc.invalid/v2/path-secret?token=z#w"
    raw = "x|y|z|w|path-secret"
    sanitized = sanitize_rpc_text(
        raw,
        url,
        url_replacement="<URL>",
        credential_replacement="<SECRET>",
    )
    if any(secret in sanitized for secret in ("x", "y", "z", "w", "path-secret")):
        raise ValueError("short explicit RPC credentials were not redacted")


def assert_bearer_is_redacted() -> None:
    bearer = "synthetic-separate-bearer"
    sanitized = sanitize_rpc_text(
        f"Authorization: Bearer {bearer}",
        "https://rpc.example/",
        bearer=bearer,
        url_replacement="<URL>",
        credential_replacement="<SECRET>",
    )
    if bearer in sanitized or "<SECRET>" not in sanitized:
        raise ValueError("separate RPC bearer was not redacted")


def main() -> int:
    assert_unavailable_warning(
        run_gate(FORK_GATE, cwd=ROOT, release=False, rpc_url=None),
        github_actions=False,
    )
    assert_unavailable_warning(
        run_gate(FORK_GATE, cwd=ROOT, release=False, rpc_url=None, github_actions=True),
        github_actions=True,
    )
    assert_release_modes()
    assert_authenticated_release_modes()
    assert_short_explicit_credentials_are_redacted()
    assert_bearer_is_redacted()
    print(
        "Fork-evidence policy passed "
        "(development warning plus fail-closed pinned/live absence, failure, completeness, "
        "sanitization, identity, and process-group cleanup fixtures tested)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
