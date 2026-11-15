"""Validate exact source bytes against the independently inventoried build64.

The older build62 baseline was overwritten by previous releases. It remains as a
historical file, but is not used as provenance. The frozen build64 baseline was
matched against all 591 files in the actual build container AND git 06d5e1b.

Version and build are read from <root>/release.json (F-41). Resources/Info.plist
is a static file and cannot read it, so the two must be edited together; the
'Info.plist release mismatch' assertion below is what catches a missed sync.
"""
import hashlib
import json
import plistlib
from pathlib import Path
import re
import sys

BASELINE = 'tests/baseline-1.20.2-build64.json'
BASELINE_SHA256 = 'fc79a18448f76fd33d354a3da0f8f2e1d00faec130a5abe928ed6061620d7bb3'
# Scope file name follows the release number, so bumping build never needs a
# code edit here (F-41).
SCOPE_TEMPLATE = 'tests/release-scope-build{build}.json'
IGNORED = {'.git', '.build', '.bsp', 'releases', 'release', 'DerivedData', 'HermesShellCI.xcodeproj', 'outputs', '__pycache__'}
# F-41: version/build live in release.json and nowhere else. There is no
# hardcoded fallback on purpose: a missing or malformed file must fail the gate
# loudly instead of silently validating the previous release.
RELEASE = 'release.json'
# Patterns for "this script still carries its own copy of the release number".
# They match a literal version/build pair, not the current values, so bumping
# the release never weakens the check.


def require(condition, message):
    if not condition:
        raise ValueError(message)


def load_release(root):
    """Return (version, build) read from <root>/release.json."""
    path = root / RELEASE
    require(path.is_file(), f'{RELEASE} not found at {path}: it is the single '
            'source of truth for version/build (F-41)')
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except json.JSONDecodeError as error:
        raise ValueError(f'{RELEASE} is not valid JSON: {error}')
    require(isinstance(data, dict), f'{RELEASE} must contain a JSON object')
    version, build = data.get('version'), data.get('build')
    require(isinstance(version, str) and version.strip(),
            f'{RELEASE} has no non-empty "version" string')
    require(isinstance(build, str) and build.strip(),
            f'{RELEASE} has no non-empty "build" string')
    require(version == version.strip() and build == build.strip(),
            f'{RELEASE} values must not be padded with whitespace')
    return version, build


# Module-level copies exist only for external callers that inspect the gate's
# idea of the release (tests/sourcegate/main.py tampers Info.plist with
# gate.VERSION). verify() re-reads the file from the tree it is given, so the
# gate validates a copied tree against that copy's release.json.
try:
    VERSION, BUILD = load_release(Path(__file__).resolve().parents[1])
except ValueError:
    # Keep the import working so a missing or broken release.json surfaces as a
    # clean SOURCE_GATE_FAILED from verify(), not an import-time traceback in
    # tests/sourcegate/main.py. verify() calls load_release() itself and raises
    # the specific message, so nothing is silently defaulted here.
    VERSION, BUILD = None, None


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(root):
    files = {}
    for path in sorted(root.rglob('*')):
        rel = path.relative_to(root)
        if any(part in IGNORED for part in rel.parts):
            continue
        require(not path.is_symlink(), f'source symlink: {rel}')
        if path.is_file():
            files[rel.as_posix()] = digest(path)
    return files


def verify(root):
    require(digest(root / BASELINE) == BASELINE_SHA256, 'immutable build64 baseline changed')
    version, build = load_release(root)
    baseline = json.loads((root / BASELINE).read_text(encoding='utf-8'))
    require(len(baseline) == 591, 'unexpected build64 inventory')
    scope_path = root / SCOPE_TEMPLATE.format(build=build)
    scope = json.loads(scope_path.read_text(encoding='utf-8'))
    require(scope['base_commit'] == '06d5e1b5ecf24bf29d188f46919e0ce0c707f229', 'wrong base commit')
    require(scope['version'] == version and scope['build'] == build, 'scope release mismatch')
    current = inventory(root)
    changed = {name for name in baseline.keys() & current.keys() if baseline[name] != current[name]}
    added = current.keys() - baseline.keys()
    removed = baseline.keys() - current.keys()
    for category, actual in [('changed', changed), ('added', added), ('removed', removed)]:
        declared = scope[category]
        require(len(declared) == len(set(declared)), f'duplicate {category} entries')
        for name in declared:
            require(name and not name.startswith('/') and '..' not in Path(name).parts
                    and '\\' not in name, f'invalid source path: {name}')
        require(actual == set(declared),
                f'{category} scope mismatch: undeclared={sorted(actual - set(declared))}; '
                f'not present={sorted(set(declared) - actual)}')
    # 内容哈希校验（P0-03）：只比对文件名集合无法发现「已放行文件被再次改写」，
    # 门禁会照样 pass。scope 里若有 hashes，则逐文件核对当前内容哈希。
    hashes = scope.get('hashes') or {}
    if hashes:
        mismatched = []
        missing = []
        for name, expected in hashes.items():
            if name not in current:
                missing.append(name)
            elif current[name] != expected:
                mismatched.append(name)
        require(not missing, f'hashed files missing: {sorted(missing)}')
        require(not mismatched,
                'source content drifted from the declared hashes: '
                f'{sorted(mismatched)}. Re-review and regenerate the scope, do not just re-hash.')
    # 只核对仍然存在的历史清单：仅保留最近 3 版的 baseline / manual，
    # 被裁掉的那些必须逐条写进本版 scope 的 removed，不能静默消失。
    for name in baseline:
        if not (name.startswith('tests/baseline-') or name == 'tests/release-baseline.json'):
            continue
        if name in removed:
            continue
        require(current.get(name) == baseline[name], f'immutable historical manifest changed: {name}')
    info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
    require(info['CFBundleShortVersionString'] == version and info['CFBundleVersion'] == build,
            'Info.plist release mismatch')
    readme_title = (root / 'README.md').read_text(encoding='utf-8').splitlines()[0]
    expected_readme_title = f'# Hermes {version} / build{build}'
    require(readme_title == expected_readme_title,
            f'README release mismatch: expected {expected_readme_title!r}, got {readme_title!r}')
    settings_copy = (root / 'Sources/HermesShell/LoginSettings.swift').read_text(encoding='utf-8')
    require(settings_copy.count('清晰、可靠、顺手。') == 1,
            'settings About line must exist exactly once')
    project = (root / 'ios-ci-project.yml').read_text(encoding='utf-8')
    require('PRODUCT_BUNDLE_IDENTIFIER: com.whale7.hermes' in project,
            'candidate bundle ID changed')
    return {
        'source_gate': 'pass', 'version': version, 'build': build,
        'release_source': RELEASE,
        'base_commit': scope['base_commit'], 'build64_baseline_files': len(baseline),
        'build64_baseline_sha256': BASELINE_SHA256,
        'baseline_origin': 'actual build64 directory, independently matched to git 06d5e1b',
        'preserved_build64_files': len(baseline) - len(changed) - len(removed),
        'changed_from_build64': sorted(changed), 'approved_added': sorted(added),
        'approved_removed': sorted(removed), 'current_files': len(current),
    }


if __name__ == '__main__':
    try:
        root = Path(sys.argv[1]).resolve() if len(sys.argv) == 2 else Path(__file__).resolve().parents[1]
        print(json.dumps(verify(root), ensure_ascii=False))
    except (ValueError, KeyError, OSError) as error:
        print(f'SOURCE_GATE_FAILED: {error}', file=sys.stderr)
        sys.exit(1)
