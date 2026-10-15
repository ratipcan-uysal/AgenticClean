#!/usr/bin/env python3
"""Snapshot production UI/core into an isolated, test-only XcodeGen project."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

parser = argparse.ArgumentParser()
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
manifest = {}

def snapshot(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    manifest[str(source.relative_to(root))] = hashlib.sha256(source.read_bytes()).hexdigest()

for component in ('ProcessKit', 'CleanerCore'):
    for source in sorted((root / 'Sources' / component).rglob('*')):
        if source.is_file():
            snapshot(source, out / 'Libraries' / 'Sources' / component / source.relative_to(root / 'Sources' / component))
for source in sorted((root / 'Sources' / 'Cleaner').glob('*.swift')):
    if source.name != 'Cleaner.swift':
        snapshot(source, out / 'ProductionUI' / source.name)
for folder in ('Harness', 'UITests'):
    for source in sorted((root / 'Tests' / 'NativeUI' / folder).rglob('*')):
        if source.is_file():
            snapshot(source, out / folder / source.relative_to(root / 'Tests' / 'NativeUI' / folder))
(out / 'Libraries' / 'Package.swift').write_text('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "CleanerNativeUITestLibraries", platforms: [.macOS(.v14)],
  products: [.library(name: "CleanerCore", targets: ["CleanerCore"])],
  targets: [.target(name: "ProcessKit"),
    .target(name: "CleanerCore", dependencies: ["ProcessKit"],
      swiftSettings: [.unsafeFlags(["-enable-testing"])])])
''')
spec = {
    'name': 'CleanerNativeUI',
    'options': {'deploymentTarget': {'macOS': '14.0'}, 'createIntermediateGroups': True},
    'packages': {'CleanerLibraries': {'path': 'Libraries'}},
    'settings': {'base': {'SWIFT_VERSION': '6.0', 'CODE_SIGN_IDENTITY': '-',
                          'ENABLE_HARDENED_RUNTIME': False, 'CODE_SIGN_STYLE': 'Manual',
                          'MACOSX_DEPLOYMENT_TARGET': '14.0'}},
    'targets': {
        'CleanerNativeUIHarness': {
            'type': 'application', 'platform': 'macOS',
            'sources': ['ProductionUI', 'Harness'],
            'dependencies': [{'package': 'CleanerLibraries', 'product': 'CleanerCore'}],
            'settings': {'base': {
                'PRODUCT_BUNDLE_IDENTIFIER': 'local.cleaner.native-ui-harness',
                'SWIFT_DEFAULT_ACTOR_ISOLATION': 'MainActor',
                'OTHER_SWIFT_FLAGS': '$(inherited) -enable-upcoming-feature NonisolatedNonsendingByDefault',
                'ENABLE_APP_SANDBOX': False, 'GENERATE_INFOPLIST_FILE': True,
                'INFOPLIST_KEY_LSUIElement': False,
                'INFOPLIST_KEY_CFBundleDisplayName': 'AgenticClean Native UI Fixture',
                'INFOPLIST_KEY_NSHumanReadableCopyright': 'Test-only synthetic fixture',
            }},
        },
        'CleanerNativeUITests': {
            'type': 'bundle.ui-testing', 'platform': 'macOS', 'sources': ['UITests'],
            'dependencies': [{'target': 'CleanerNativeUIHarness'}],
            'settings': {'base': {
                'PRODUCT_BUNDLE_IDENTIFIER': 'local.cleaner.native-ui-harness.tests',
                'GENERATE_INFOPLIST_FILE': True,
                'TEST_TARGET_NAME': 'CleanerNativeUIHarness',
            }},
        },
    },
    'schemes': {'CleanerNativeUI': {
        'build': {'targets': {'CleanerNativeUIHarness': 'all', 'CleanerNativeUITests': ['test']}},
        'test': {'targets': ['CleanerNativeUITests'], 'gatherCoverageData': False,
                 'parallelizable': False, 'randomExecutionOrder': False},
    }},
}
(out / 'project.yml').write_text(json.dumps(spec, indent=2) + '\n')
(out / 'source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(out / 'project.yml')
