#!/usr/bin/env python3
"""Generate the retained base ABI with its original compiler profile.

Foundry's additional compiler profiles use distinct AST identities. Keep the
retained base topology in its own output bank so the shared Protocol generator
reads immutable declarations from the same compilation as those facets. The
universal extension is generated separately from its IR compilation.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
output = Path(os.environ.get('FOUNDRY_OUT', str(ROOT / 'out')))
if not output.is_absolute():
    output = ROOT / output
# Incremental jobs can assign a new immutable AST ID while retaining an older
# facet artifact. One fresh bank keeps every declaration/reference in the same
# compilation, including standalone generation outside the isolated CI runner.
output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='release-abi-', dir=output) as directory:
    bank = Path(directory)
    environment = dict(os.environ, FOUNDRY_OUT=str(bank / 'out'),
                       FOUNDRY_CACHE_PATH=str(bank / 'cache'),
                       FOUNDRY_SKIP='["TradeExactInFacet.sol","TradeExactInputDeployment.sol"]')
    raise SystemExit(subprocess.call([
        sys.executable, str(ROOT / 'lib/cybergold-protocol/script/generate-release-abi.py'),
        '--root', str(ROOT), '--config', 'script/config/helpers-release-abi.json', *sys.argv[1:]],
        cwd=ROOT, env=environment))
