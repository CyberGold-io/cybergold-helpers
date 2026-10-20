#!/usr/bin/env python3
"""Union real LCOV observations from default and exact-input compiler banks.

Source positions and function names identify the same authored code across
compiler profiles. Counters are added; missing observations remain uncovered.
No exclusions or synthetic hits are introduced here.
"""
from pathlib import Path
import sys


def merge(paths: list[Path]) -> dict:
    sources: dict = {}
    for path in paths:
        source = None
        for raw in path.read_text().splitlines():
            field, _, value = raw.partition(':')
            if field == 'SF':
                source = sources.setdefault(value, {'lines': {}, 'functions': {}, 'branches': {}})
            elif source is not None and field == 'DA':
                line, hits, *_ = value.split(',')
                source['lines'][int(line)] = source['lines'].get(int(line), 0) + int(hits)
            elif source is not None and field == 'FN':
                line, name = value.split(',', 1)
                source['functions'].setdefault(name, {'line': int(line), 'hits': 0})
            elif source is not None and field == 'FNDA':
                hits, name = value.split(',', 1)
                source['functions'][name]['hits'] += int(hits)
            elif source is not None and field == 'BRDA':
                line, block, branch, hits = value.split(',')
                key = (int(line), int(block), int(branch))
                source['branches'][key] = source['branches'].get(key, 0) + (0 if hits == '-' else int(hits))
            elif field == 'end_of_record':
                source = None
    return sources


def render(sources: dict) -> str:
    output: list[str] = []
    for name, source in sorted(sources.items()):
        output.extend(('TN:', 'SF:' + name))
        for function, values in sorted(source['functions'].items(), key=lambda item: (item[1]['line'], item[0])):
            output.extend((f"FN:{values['line']},{function}", f"FNDA:{values['hits']},{function}"))
        for line, hits in sorted(source['lines'].items()):
            output.append(f'DA:{line},{hits}')
        for key, hits in sorted(source['branches'].items()):
            output.append('BRDA:' + ','.join(map(str, (*key, hits))))
        output.extend((f"FNF:{len(source['functions'])}",
                       f"FNH:{sum(value['hits'] > 0 for value in source['functions'].values())}",
                       f"LF:{len(source['lines'])}", f"LH:{sum(hits > 0 for hits in source['lines'].values())}",
                       f"BRF:{len(source['branches'])}", f"BRH:{sum(hits > 0 for hits in source['branches'].values())}",
                       'end_of_record'))
    return '\n'.join(output) + '\n'


if __name__ == '__main__':
    destination = Path(sys.argv[1])
    destination.write_text(render(merge(list(map(Path, sys.argv[2:])))))
