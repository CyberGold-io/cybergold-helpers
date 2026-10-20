#!/usr/bin/env python3
"""Export the universal extension and explicit migration inventory from compiled ABIs."""
import argparse
import json
import os
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
out = Path(os.environ.get('FOUNDRY_OUT', 'out'))
if not out.is_absolute():
    out = root / out
interface = json.loads((out / 'ITradeExactInput.sol/ITradeExactInput.json').read_text())
facet = json.loads((out / 'TradeExactInFacet.sol/TradeExactInFacet.json').read_text())
legacy = json.loads((root / 'generated/abi/HelpersDiamond.json').read_text())
market = json.loads((root / 'generated/abi/HelpersMarket.json').read_text())
old = legacy['selectors'] + market['selectors']
migration = json.loads((root / 'script/config/helpers-exact-input-migration.json').read_text())
removed = migration['removeExecution']
preview_in = [s for s in old if s['signature'].startswith('preview') and 'ExactIn(' in s['signature']]
preview_out = [s for s in old if s['signature'].startswith('preview') and 'ExactOut(' in s['signature']]
exact_out = [s for s in old if not s['signature'].startswith('preview')
             and ('ExactOut(' in s['signature'] or 'ExactOutWith' in s['signature'] or s['signature'].startswith('swapExactOutput('))]
selectors = [{'signature': signature, 'selector': '0x' + selector, 'facet': 'tradeExactInput'}
             for signature, selector in interface['methodIdentifiers'].items()
             if signature.startswith('executeExactInput(')]
result = {
    'schemaVersion': '2.0', 'contractName': 'HelpersExactInput', 'extensionOf': 'HelpersDiamond',
    'interface': {'name': 'ITradeExactInput', 'source': 'src/interfaces/ITradeExactInput.sol',
                  'erc165Advertised': False, 'selectors': selectors},
    'selectors': selectors, 'abi': interface['abi'],
}
links = facet['bytecode'].get('linkReferences', {})
topology = {
    'schemaVersion': 1, 'contractName': 'HelpersExactInput',
    'source': 'src/facets/TradeExactInFacet.sol', 'selectors': selectors,
    'namespace': 'cybergold.helpers.trade.exact-input',
    'constructorBindings': {'permit2_': 'existing Helpers release Permit2',
                            'adapter_': 'deployed UniswapRoutingAdapter successor'},
    'linkedLibraries': sorted(f'{source}:{name}' for source, values in links.items() for name in values),
    'compilerProfile': 'exact_input', 'viaIR': True,
    'settlementPolicy': 'protocol-retention', 'retainedCustodian': 'Helpers Diamond',
    'routerVersion': '2.2.0',
    'adapterPayload': {'name': 'IUniswapRoutingTypes.SwapPlan',
                      'source': 'src/interfaces/IUniswapRoutingTypes.sol',
                      'publicHookFields': False},
    'migration': {'activationThenCallerAdoptionThenRetirement': True,
                  'removeExecution': removed, 'retainExactInputPreviews': preview_in,
                  'retainExactOutputExecution': exact_out, 'retainExactOutputPreviews': preview_out,
                  'expectedConsolidatedSelectorCount': len(old) + len(selectors),
                  'revokeUniswapAdapters': ['0x4edb8190232a47e45d861003672938eb7ee84a15',
                                            '0xc2c210979674db1349f812ea116f2f6d131ab839']},
}
for relative, value in [('generated/abi/HelpersExactInput.json', result),
                        ('generated/topology/HelpersExactInput.json', topology)]:
    path = root / relative
    rendered = json.dumps(value, indent=2) + '\n'
    if args.check:
        if path.read_text() != rendered:
            raise SystemExit(f'{relative}: regenerate universal exact-input artifact')
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rendered)
print('Universal exact-input ABI/topology ' + ('verified' if args.check else 'generated'))
