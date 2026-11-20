#!/usr/bin/env python3
"""Reproduce Oriv's unmodified, pinned MPL-2.0 package files."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / 'Packages/BrowserKit/Sources/BrowserEngine/Resources/Privacy/Autoconsent'
FILES = {
    'autoconsent.cjs.js': 'package/dist/autoconsent.cjs.js',
    'compact-rules.json': 'package/rules/compact-rules.json',
    'MPL-2.0.txt': 'package/LICENSE',
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='use an existing copy of the pinned npm archive')
    parser.add_argument('--check', action='store_true', help='verify the checked-in files without writing')
    options = parser.parse_args()
    manifest = json.loads((DESTINATION / 'manifest.json').read_text())
    version = manifest['version']
    if options.archive:
        raw = options.archive.read_bytes()
    else:
        url = f'https://registry.npmjs.org/@duckduckgo/autoconsent/-/autoconsent-{version}.tgz'
        with urllib.request.urlopen(url, timeout=30) as response:
            raw = response.read()
    if hashlib.sha256(raw).hexdigest() != manifest['packageSHA256']:
        raise SystemExit('Pinned archive digest mismatch')

    verified = {}
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
        for filename, member in FILES.items():
            with archive.extractfile(member) as source:
                data = source.read()
            if hashlib.sha256(data).hexdigest() != manifest['files'][filename]:
                raise SystemExit(f'Vendored file digest mismatch: {filename}')
            verified[filename] = data
    for filename, data in verified.items():
        path = DESTINATION / filename
        if options.check:
            if path.read_bytes() != data:
                raise SystemExit(f'Checked-in file differs from upstream: {filename}')
        else:
            path.write_bytes(data)
    print(f'Autoconsent {version}: verified {len(verified)} pinned files')


if __name__ == '__main__':
    main()
