#!/usr/bin/env python3
"""Create a reviewable source archive, never publish or include private Git history."""
import pathlib
import re
import tarfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
FILES = ["Package.swift", "VERSION", "LICENSE", "README.md", "README.en.md", "SECURITY.md",
         ".gitignore", "CONTRIBUTING.md", "docs/ALPHA.md", "docs/RELEASING.md", "docs/CACHE-SCOPE.md", "CHANGELOG.md"]
TREES = ["Sources", "Tests", "scripts", ".github"]

def main():
    selected = [ROOT / name for name in FILES if (ROOT / name).is_file()]
    for name in TREES:
        selected.extend(path for path in (ROOT / name).rglob("*") if path.is_file())
    selected = sorted(set(selected))
    rejected = []
    for path in selected:
        if path.is_symlink() or any((ROOT / parent).is_symlink() for parent in path.relative_to(ROOT).parents if parent != pathlib.Path('.')):
            rejected.append(str(path.relative_to(ROOT)) + ': symlink')
            continue
        raw = path.read_bytes()
        if path.suffix in ('.p12', '.pem', '.key') or re.search(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', raw):
            rejected.append(str(path.relative_to(ROOT)) + ': private key material')
        # Explicitly reject the current host's personal home path, while allowing synthetic /Users/test fixtures.
        if str(pathlib.Path.home()).encode() in raw:
            rejected.append(str(path.relative_to(ROOT)) + ': personal home path')
    if rejected:
        raise SystemExit('Archive refused:\n' + '\n'.join(rejected))
    version = (ROOT / 'VERSION').read_text().strip()
    target = ROOT / 'dist' / f'AgenticClean-{version}-source.tar.gz'
    target.parent.mkdir(exist_ok=True)
    with tarfile.open(target, 'w:gz') as archive:
        for path in selected:
            info = archive.gettarinfo(str(path), arcname='AgenticClean/' + str(path.relative_to(ROOT)))
            info.uid = info.gid = 0
            info.uname = info.gname = ''
            with path.open('rb') as source:
                archive.addfile(info, source)
    print(f'{len(selected)} source files: {target}')
    print('No Git history, dist/build files, or local verification reports included. Review before publishing.')

if __name__ == '__main__':
    main()
