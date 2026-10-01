#!/usr/bin/env python3
"""Host the exact signed release; reject any asset that differs from its checksum."""
import hashlib
import json
import pathlib
import shutil
import urllib.request

root = pathlib.Path(__file__).resolve().parent.parent
release = json.loads((root / 'release.json').read_text())
public = root / 'public'
public.mkdir(exist_ok=True)
target = public / release['filename']
with urllib.request.urlopen(release['url']) as response, target.open('wb') as output:
    shutil.copyfileobj(response, output)
if hashlib.sha256(target.read_bytes()).hexdigest() != release['sha256']:
    target.unlink()
    raise RuntimeError('Release download failed SHA-256 verification')
(public / 'SHA256SUMS.txt').write_text(f"{release['sha256']}  {release['filename']}\n")
shutil.copyfile(root / 'docs/screenshot.png', public / 'screenshot.png')
shutil.copyfile(root / 'README.md', public / 'instructions.txt')
print(f"Verified {release['filename']}")
