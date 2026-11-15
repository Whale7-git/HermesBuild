#!/usr/bin/env python3
"""Regenerate tests/release-scope-build<build>.json from the current tree.

The source gate (tests/verify_source.py) compares the working tree against the
frozen build64 baseline and against this scope file. Any change to a file that
still matches the baseline makes the gate fail with
`changed scope mismatch: undeclared=[...]` until the scope is regenerated.

This script is the supported way to regenerate it. Do NOT hand-edit the scope
JSON and do NOT recompute the baseline: the baseline is the frozen reference and
rewriting it would erase the very drift the gate exists to catch.

Usage:
    cd HermesBuild
    python3 tests/gen_release_scope.py

One invocation suffices even when the build-specific scope file did not exist.
The scope file is added to its own inventory by path but excluded from its
content hashes, avoiding a self-referential checksum.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

# Never walk into build output, caches, or delivery directories: they are large
# and none of them are source the gate should pin.
IGNORED = {'.git', '.build', '.bsp', 'xtool', 'releases', 'release', 'DerivedData', 'HermesShellCI.xcodeproj', 'outputs', '__pycache__'}

BASELINE_NAME = 'tests/baseline-1.20.2-build64.json'
RELEASE_NAME = 'release.json'


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    release_path = root / RELEASE_NAME
    baseline_path = root / BASELINE_NAME
    if not release_path.is_file():
        print(f'{RELEASE_NAME} not found at {root}', file=sys.stderr)
        return 2
    if not baseline_path.is_file():
        print(f'{BASELINE_NAME} not found at {root}', file=sys.stderr)
        return 2

    release = json.loads(release_path.read_text(encoding='utf-8'))
    version, build = release['version'], release['build']
    scope_name = f'tests/release-scope-build{build}.json'

    # The gate's own metadata cannot pin itself, and release.json is the input to
    # the version it pins, so both stay out of the hash set.
    self_excluded = {
        'tests/verify_source.py',
        scope_name,
        BASELINE_NAME,
        RELEASE_NAME,
    }

    baseline = json.loads(baseline_path.read_text(encoding='utf-8'))

    current: dict[str, str] = {}
    for path in sorted(root.rglob('*')):
        rel = path.relative_to(root)
        if any(part in IGNORED for part in rel.parts):
            continue
        if path.is_file():
            current[rel.as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()

    # New build IDs still declare the scope path on the first invocation.
    # Its own bytes are excluded from the hash set below.
    current.setdefault(scope_name, '')
    changed = sorted(n for n in baseline.keys() & current.keys()
                     if baseline[n] != current[n])
    added = sorted(current.keys() - baseline.keys())
    removed = sorted(baseline.keys() - current.keys())
    hashes = {n: current[n] for n in sorted(set(changed) | set(added))
              if n in current and n not in self_excluded}

    out = {
        'base_commit': '06d5e1b5ecf24bf29d188f46919e0ce0c707f229',
        'version': version,
        'build': build,
        'changed': changed,
        'added': added,
        'removed': removed,
        'hashes': hashes,
    }
    target = root / scope_name
    # write_bytes, never write_text: on Windows the latter emits CRLF, and the
    # shell scripts in this repo break on CRLF (`set: pipefail: invalid option name`).
    target.write_bytes((json.dumps(out, ensure_ascii=False, indent=2) + '\n').encode('utf-8'))

    print(f'version {version} build {build}')
    print(f'files {len(current)} changed {len(changed)} added {len(added)} '
          f'removed {len(removed)} hashed {len(hashes)}')
    print(f'wrote {scope_name}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
