#!/usr/bin/env python3
"""Regression for cross-profile observations without manufacturing missing hits."""
from pathlib import Path
import runpy
import tempfile
import unittest

MODULE = runpy.run_path(str(Path(__file__).with_name('merge-helpers-coverage.py')))


class CoverageUnionTest(unittest.TestCase):
    def test_complementary_observations_preserve_uncovered_code(self):
        template = ('TN:\nSF:src/Example.sol\nFN:1,Example.run\nFNDA:1,Example.run\n'
                    'DA:1,1\nDA:2,0\nBRDA:1,0,0,{left}\nBRDA:1,0,1,{right}\n'
                    'end_of_record\n')
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ('default.lcov', 'ir.lcov')]
            paths[0].write_text(template.format(left=1, right=0))
            paths[1].write_text(template.format(left=0, right=1))
            result = MODULE['render'](MODULE['merge'](paths))
        self.assertIn('DA:1,2\n', result)
        self.assertIn('DA:2,0\n', result)
        self.assertIn('BRH:2\n', result)
        self.assertIn('LF:2\nLH:1\n', result)
        self.assertIn('FNF:1\nFNH:1\n', result)


if __name__ == '__main__':
    unittest.main()
