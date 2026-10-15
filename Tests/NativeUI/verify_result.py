#!/usr/bin/env python3
"""Fail closed unless every declared native UI test executed and passed."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('result', type=Path)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
expected = sorted(set(re.findall(r'func\s+(test\w+)\s*\(', args.source.read_text())))
report = {'status': 'UNKNOWN', 'expected': expected, 'executed': [], 'problems': []}
try:
    result = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', 'tests',
                             '--path', str(args.result), '--compact'],
                            check=True, capture_output=True, text=True)
    raw = json.loads(result.stdout)
    args.output.with_name('test-tree.json').write_text(json.dumps(raw, indent=2) + '\n')
    executed = []
    def visit(node):
        if node.get('nodeType') == 'Test Case':
            name = node.get('name', '').split('/')[-1].removesuffix('()')
            executed.append({'name': name, 'result': node.get('result', 'unknown'),
                             'identifier': node.get('nodeIdentifier')})
        for child in node.get('children', []):
            visit(child)
    for node in raw.get('testNodes', []):
        visit(node)
    report['executed'] = executed
    if not expected:
        report['problems'].append('Expected test set is empty')
    actual = [test['name'] for test in executed]
    if sorted(actual) != expected:
        report['problems'].append('Executed tests differ from the expected nonempty test set')
    if any(test['result'] != 'Passed' for test in executed):
        report['problems'].append('At least one test failed, skipped or has an unknown result')
    report['status'] = 'FAIL' if report['problems'] else 'PASS'
except (OSError, ValueError, subprocess.CalledProcessError) as error:
    report['problems'].append(str(error))
args.output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
sys.exit(0 if report['status'] == 'PASS' else 1)
