#!/usr/bin/env python3
"""Publish exact, verified CI bytes through a draft; never overwrite a release."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import quote


class GitHub:
    def __init__(self, repo):
        self.repo = repo

    def api(self, path, method='GET', data=None, missing=False):
        args = ['gh', 'api', '--include', '--method', method, f'repos/{self.repo}/{path}']
        if data is not None:
            args += ['--input', '-']
        result = subprocess.run(args, input=json.dumps(data) if data is not None else None,
                                text=True, capture_output=True)
        header, separator, body = result.stdout.partition('\n\n')
        match = re.search(r'^HTTP/\S+ (\d+)', header)
        status = int(match[1]) if match else 0
        if status == 404 and missing:
            return None
        if result.returncode or not 200 <= status < 300 or not separator:
            raise RuntimeError(f'GitHub {method} {path} failed (HTTP {status})')
        return json.loads(body) if body.strip() else None

    def upload(self, tag, paths):
        subprocess.run(['gh', 'release', 'upload', tag, '--repo', self.repo,
                        *map(str, paths)], check=True)

    def download(self, asset, destination):
        with destination.open('wb') as output:
            subprocess.run(['gh', 'api', '-H', 'Accept: application/octet-stream',
                            f'repos/{self.repo}/releases/assets/{asset["id"]}'],
                           stdout=output, check=True)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def context(env):
    if (env.get('GITHUB_REPOSITORY') != 'Whale7-git/HermesBuild'
            or env.get('GITHUB_EVENT_NAME') != 'push' or env.get('GITHUB_REF') != 'refs/heads/main'):
        raise ValueError('automatic publication requires a HermesBuild main push')
    sha, run = env.get('GITHUB_SHA', ''), env.get('GITHUB_RUN_ID', '')
    if not re.fullmatch(r'[0-9a-f]{40}', sha) or not re.fullmatch(r'[1-9]\d*', run):
        raise ValueError('invalid source or workflow identity')
    return sha, run


def release_identity(root):
    meta = json.loads((root / 'release.json').read_text())
    version, build = meta.get('version'), meta.get('build')
    if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('invalid version')
    if not isinstance(build, str) or not re.fullmatch(r'[1-9]\d*', build):
        raise ValueError('invalid build')
    return version, build, f'release-{version}-build{build}'


def validate_bundle(root, sha):
    version, build, tag = release_identity(root)
    directory = root / 'release'
    name = f'Hermes-{version}-build{build}-unsigned.ipa'
    names = {name, 'build-info.json', 'validation.json', 'SHA256SUMS.txt'}
    if set(p.name for p in directory.iterdir()) != names:
        raise ValueError('release directory must contain exactly the four expected assets')
    paths = {n: directory / n for n in names}
    if any(p.is_symlink() or not p.is_file() or p.stat().st_size == 0 for p in paths.values()):
        raise ValueError('release assets must be nonempty regular files')
    checksums = {}
    for line in paths['SHA256SUMS.txt'].read_text().splitlines():
        m = re.fullmatch(r'([a-f0-9]{64}) [ *]([^/\\]+)', line)
        if not m or m[2] in checksums:
            raise ValueError('invalid checksum manifest')
        checksums[m[2]] = m[1]
    if set(checksums) != names - {'SHA256SUMS.txt'}:
        raise ValueError('checksum manifest does not cover exactly the package and reports')
    if any(digest(paths[n]) != value for n, value in checksums.items()):
        raise ValueError('release asset checksum mismatch')
    info = json.loads(paths['build-info.json'].read_text())
    report = json.loads(paths['validation.json'].read_text())
    if (info.get('head_commit') != sha or info.get('source_head_commit') != sha
            or info.get('working_tree') != 'clean'
            or (info.get('version'), info.get('build')) != (version, build)):
        raise ValueError('build provenance does not match the exact source')
    if (report.get('ipa') != name or (report.get('version'), report.get('build')) != (version, build)
            or report.get('bundle') != 'com.whale7.hermes' or report.get('arch') != 'arm64'
            or report.get('unsigned') is not True or report.get('sha256') != checksums[name]):
        raise ValueError('IPA validation report mismatch')
    # Independently inspect the same bytes before exposing a public Release.
    subprocess.run(['python3', str(root / 'tests/verify_ipa.py'), str(paths[name]), version, build,
                    str(paths['build-info.json']), '--label', name], check=True)
    return version, build, tag, paths


def preflight(client, tag, sha, run):
    release = client.api('releases/tags/' + quote(tag), missing=True)
    if release is not None:
        marker = f'Source commit: {sha}\nWorkflow run: {run}'
        if (release.get('draft') is not True or marker + '\n' not in (release.get('body') or '') + '\n'
                or release.get('target_commitish') != sha):
            raise ValueError('tag/release already exists; published or foreign releases are immutable')
        ref = client.api('git/ref/tags/' + quote(tag), missing=True)
        if ref is not None and (ref['object'].get('type') != 'commit' or ref['object'].get('sha') != sha):
            raise ValueError('draft tag does not match the source')
        return release
    if client.api('git/ref/tags/' + quote(tag), missing=True) is not None:
        raise ValueError('release tag already exists')
    return None


def verify_remote(client, release, paths):
    assets = release.get('assets', [])
    if len(assets) != len(paths) or {a['name'] for a in assets} != set(paths):
        raise ValueError('uploaded release assets are incomplete or unexpected')
    with tempfile.TemporaryDirectory(prefix='hermes-release-verify-') as temp:
        for asset in assets:
            original = paths[asset['name']]
            if asset.get('size') != original.stat().st_size:
                raise ValueError('remote asset size mismatch')
            downloaded = Path(temp) / asset['name']
            client.download(asset, downloaded)
            if digest(downloaded) != digest(original):
                raise ValueError('remote asset SHA256 mismatch')


def publish(client, tag, sha, run, paths):
    release = preflight(client, tag, sha, run)
    if release is None:
        release = client.api('releases', 'POST', dict(tag_name=tag, target_commitish=sha,
                             name=tag, draft=True, prerelease=False,
                             body=f'Source commit: {sha}\nWorkflow run: {run}\n\nUnsigned iPhoneOS arm64 IPA; source/offline regression and IPA validation passed. Device signing and acceptance remain separate.'))
    rid = release['id']
    # Resume partial uploads by reusing only exact existing bytes; never clobber
    # an asset, even if another actor changes the draft concurrently.
    existing = release.get('assets', [])
    if len({a['name'] for a in existing}) != len(existing) or any(a['name'] not in paths for a in existing):
        raise ValueError('draft contains unexpected or duplicate assets')
    verify_remote(client, release, {a['name']: paths[a['name']] for a in existing})
    pending = [paths[n] for n in sorted(set(paths) - {a['name'] for a in existing})]
    if pending:
        client.upload(tag, pending)
    staged = client.api(f'releases/{rid}')
    if (staged.get('draft') is not True or staged.get('tag_name') != tag
            or staged.get('target_commitish') != sha):
        raise ValueError('draft identity changed during upload')
    verify_remote(client, staged, paths)
    client.api(f'releases/{rid}', 'PATCH', dict(draft=False, prerelease=False, make_latest='legacy'))
    official = client.api(f'releases/{rid}')
    if official.get('draft') is not False or official.get('prerelease') is not False or official.get('tag_name') != tag:
        raise ValueError('official release identity mismatch')
    ref = client.api('git/ref/tags/' + quote(tag))
    obj = ref['object']
    if obj.get('type') == 'tag':
        obj = client.api('git/tags/' + obj['sha'])['object']
    if obj.get('type') != 'commit' or obj.get('sha') != sha:
        raise ValueError('published tag points to another source commit')
    verify_remote(client, official, paths)
    return official['html_url']


def main():
    sha, run = context(os.environ)
    root = Path(__file__).resolve().parents[1]
    if subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True, cwd=root).strip() != sha:
        raise ValueError('checkout does not match GITHUB_SHA')
    _, _, tag = release_identity(root)
    client = GitHub(os.environ['GITHUB_REPOSITORY'])
    if '--preflight' in __import__('sys').argv:
        preflight(client, tag, sha, run)
        print('RELEASE_PREFLIGHT_PASS')
        return
    version, build, tag, paths = validate_bundle(root, sha)
    # Retry transient upload/API failures while the exact same local bytes exist.
    # A fresh job that produces different bytes must never mix bundles in a draft.
    for attempt in range(3):
        try:
            url = publish(client, tag, sha, run, paths)
            break
        except (RuntimeError, subprocess.CalledProcessError):
            if attempt == 2:
                raise
            print('Transient publication failure; retrying the same verified bundle')
            __import__('time').sleep(3 * (2 ** attempt))
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(f'url={url}\n')
    print(f'RELEASE_VERIFIED version={version} build={build} url={url}')


if __name__ == '__main__':
    main()
