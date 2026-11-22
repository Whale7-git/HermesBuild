#!/usr/bin/env python3
"""Decide whether an authorized main push or explicit merge dispatch publishes a release."""
import json
import os
from pathlib import Path
import re
import subprocess


def identity(data):
    version, build = data.get('version'), data.get('build')
    if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('version must be major.minor.patch')
    if not isinstance(build, str) or not re.fullmatch(r'[1-9]\d*', build):
        raise ValueError('build must be a positive decimal string')
    return version, build


def plan(current, previous, event, ref):
    version, build = identity(current)
    release = False
    if event in ('push', 'workflow_dispatch') and ref == 'refs/heads/main':
        if previous is None:
            raise ValueError('previous main release metadata is required')
        old_version, old_build = identity(previous)
        release = (version, build) != (old_version, old_build)
        if release and (int(build) <= int(old_build)
                        or tuple(map(int, version.split('.'))) < tuple(map(int, old_version.split('.')))):
            raise ValueError('new releases require a higher build and a non-decreasing version')
    return dict(release=str(release).lower(), version=version, build=build,
                tag=f'release-{version}-build{build}')


def main():
    event = os.environ['GITHUB_EVENT_NAME']
    ref = os.environ['GITHUB_REF']
    previous = None
    if event in ('push', 'workflow_dispatch') and ref == 'refs/heads/main':
        payload = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
        if event == 'workflow_dispatch':
            inputs = payload.get('inputs') or {}
            expected = inputs.get('expected_sha', '')
            before = inputs.get('previous_sha', '')
            actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
            parent = subprocess.check_output(['git', 'rev-parse', 'HEAD^'], text=True).strip()
            if expected != actual or before != parent or os.environ.get('GITHUB_SHA') != actual:
                raise ValueError('dispatch commit or first parent mismatch')
        else:
            before = payload.get('before', '')
        if not re.fullmatch(r'[0-9a-f]{40}', before) or before == '0' * 40:
            raise ValueError('cannot establish previous main commit; refusing automatic release')
        raw = subprocess.check_output(['git', 'show', f'{before}:release.json'], text=True)
        previous = json.loads(raw)
    result = plan(json.loads(Path('release.json').read_text()), previous, event, ref)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        for key, value in result.items():
            output.write(f'{key}={value}\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
