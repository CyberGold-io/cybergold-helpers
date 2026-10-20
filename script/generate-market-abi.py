#!/usr/bin/env python3
"""Generate the scoped market extension without rewriting historical release ABI."""
import argparse
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
output = Path(os.environ.get('FOUNDRY_OUT', 'out'))
if not output.is_absolute():
    output = root/output
artifact = json.loads((output/'MarketSwapFacet.sol/MarketSwapFacet.json').read_text())
methods = {signature: selector for signature, selector in artifact['methodIdentifiers'].items()
           if signature.startswith('swapExactOutput(')}
selectors = [{'signature': signature, 'selector': '0x'+selector, 'facet': 'marketSwap'}
             for signature, selector in sorted(methods.items(), key=lambda item:item[1])]
namespace = subprocess.check_output(['cast','keccak','cybergold.helpers.marketSwap'],text=True).strip()
interface_id = 0
for item in selectors:
    interface_id ^= int(item['selector'],16)
abi = [item for item in artifact['abi'] if item.get('name') not in ('FACET_NAMESPACE','FACET_VERSION')
       and item['type'] != 'constructor'
       and (item['type'] != 'function' or item.get('name') in ('swapExactOutput',))]
result = {'schemaVersion':'2.0','contractName':'HelpersMarket','extensionOf':'HelpersDiamond',
          'interface':{'name':'IMarketSwap','source':'src/interfaces/IMarketSwap.sol','erc165Advertised':False,
                       'selectors':selectors,'interfaceId':f'0x{interface_id:08x}'},'selectors':selectors,
          'interfaceIdInt':interface_id,
          'selectorValues':[item['selector'] for item in selectors],
          'selectorInts':[int(item['selector'],16) for item in selectors], 'abi':abi}
topology = {'schemaVersion':1,'contractName':'HelpersMarket','extensionOf':'HelpersDiamond',
            'source':'src/facets/MarketSwapFacet.sol','namespace':namespace,'selectorCount':len(selectors),
            'selectors':selectors,'initializer':None,
            'constructorBindings':{'permit2_':'existing Helpers release Permit2'},
            'storage':'Existing Helpers storage; no new persistent market namespace',
            'routerVersion':'2.2.0','routerAddress':'0xab863E752Bf67D8DCDD929EaAe9Be9dc83Fb3BbB'}
for name,value in [('generated/abi/HelpersMarket.json',result),('generated/topology/HelpersMarket.json',topology)]:
    path=root/name
    rendered=json.dumps(value,indent=2)+'\n'
    if args.check:
        if path.read_text()!=rendered: raise SystemExit(f'{name}: regenerate scoped market artifact')
    else:
        path.parent.mkdir(parents=True,exist_ok=True);path.write_text(rendered)
print('Scoped market ABI/topology '+('verified' if args.check else 'generated'))
