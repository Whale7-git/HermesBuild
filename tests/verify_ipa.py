#!/usr/bin/env python3
"""Verify a real Hermes IPA.

Usage:
    verify_ipa.py <ipa> <version> <build> [build-info.json] [--delivery PATH]
                  [--label NAME] [--no-build-info]

<version> and <build> are mandatory (F-41, P2-21). The previous defaults
('1.3.0' / None) let a manual re-check validate a stale package and still print
a pass, because the build number was never compared at all.

This tool deliberately does NOT read release.json itself. It is an independent
audit step: an auditor must state which release they expect and be told when the
package disagrees, instead of both sides reading the same file and agreeing by
construction. Callers take the two values from release.json at the repository
root and pass them explicitly, e.g.

    read -r version build < <(python3 -c 'import json;d=json.load(open("release.json"));print(d["version"],d["build"])')
    python3 tests/verify_ipa.py releases/Hermes-*.ipa "$version" "$build"

Checks:
  * exactly one Payload/*.app with the expected bundle id, version, build and
    minimum OS
  * arm64 Mach-O, no LC_CODE_SIGNATURE, no embedded provisioning profile
  * no own sources/tests/config shipped and no secret markers
  * required icons, third-party notices, Prism bundle and math fonts
  * P0 gateway symbol (F-81): the Mach-O must carry the mangled symbol of
    GatewayEventMap.rawEventName (shipped as `rawD4Name`, because Swift encodes
    a private member's access level into the mangled name). That function is the
    SSE event-name decoder, so a package built before the fix has no such
    symbol and a structure-only check used to pass a broken IPA.
  * provenance (F-81): build-info.json must exist, working_tree must be
    "clean", version/build must match, and Info.plist HermesGitSHA (when the
    plist carries it) must equal build-info.json head_commit.

build-info.json is mandatory. It is written by build-on-9.ps1 only after a
successful build, so a manual re-check of a delivery directory always finds it
and a package that never completed a clean build cannot pass. The one exception
is the in-container step, which runs before the artifact is downloaded and
before build-info.json exists; that step passes --no-build-info explicitly, and
build-on-9.ps1 then enforces the same three provenance assertions on the
downloaded copy.
"""
import hashlib
import json
import plistlib
import struct
import sys
import zipfile
from pathlib import Path

USAGE = ('usage: verify_ipa.py <ipa> <version> <build> [build-info.json] '
         '[--delivery PATH] [--label NAME] [--no-build-info]')
# Printed by --help. The version/build note is the F-41 contract: this tool is an
# independent auditor, so it takes the numbers from the caller instead of reading
# release.json itself, and the caller reads them from that file.
HELP = USAGE + '''

<version> and <build> are required and are NOT read from release.json here.
This is an independent audit step: state the release you expect and be told when
the package disagrees, rather than having both sides read the same file. Callers
take both values from release.json at the repository root and pass them in, e.g.

    read -r version build < <(python3 -c \\
      'import json;d=json.load(open("release.json"));print(d["version"],d["build"])')
    python3 tests/verify_ipa.py releases/Hermes-*.ipa "$version" "$build"

Options:
  --delivery PATH   compare the delivered copy against the built one
  --label NAME      name used in the report
  --no-build-info   skip build-info.json (in-container step only, before the
                    artifact is downloaded; build-on-9.ps1 re-checks it after)
'''
SECRET_MARKERS = (b'API_SERVER_KEY', b'hermes_session=', b'"password"', b'BEGIN PRIVATE KEY')
ARM64_MAGIC = 0xFEEDFACF
ARM64_CPU = 0x100000C
LC_SYMTAB = 0x2
LC_CODE_SIGNATURE = 0x1D
GATEWAY_SYMBOL_OWNER = 'HermesShell15GatewayEventMapO'
GATEWAY_SYMBOL_NAME = 'rawD4Name'
# The P0 marker is GatewayEventMap.rawEventName. Swift mangles a private member
# as `rawD4Name` (4 = 8-byte discriminator + hash), so the shipped symbol is
# rawD4Name while an internal/public build would carry rawEventName. Accept
# both so the gate tracks the function, not its current access level.
GATEWAY_SYMBOL_NAMES = ('rawD4Name', 'rawEventName')
GATEWAY_SYMBOL_MARKERS = (
    b'_$s11HermesShell15GatewayEventMapO03rawD4Name',
    b'_$s11HermesShell15GatewayEventMapO12rawEventName',
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def parse_args(argv):
    positional, options = [], {'label': None, 'delivery': None, 'no-build-info': False}
    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg in ('--help', '-h'):
            print(HELP)
            raise SystemExit(0)
        if arg == '--no-build-info':
            options['no-build-info'] = True
            index += 1
            continue
        matched = False
        for flag in ('label', 'delivery'):
            if arg == '--' + flag:
                require(index + 1 < len(argv), f'--{flag} needs a value\n{USAGE}')
                options[flag] = argv[index + 1]
                index += 2
                matched = True
                break
            if arg.startswith('--' + flag + '='):
                options[flag] = arg.split('=', 1)[1]
                index += 1
                matched = True
                break
        if matched:
            continue
        require(not arg.startswith('--'), f'unknown option: {arg}\n{USAGE}')
        positional.append(arg)
        index += 1
    require(3 <= len(positional) <= 4, USAGE)
    return positional, options


def inspect_macho(binary):
    """Return (load command ids, mangled symbol names or None when absent)."""
    magic, cpu, _, _, ncmds, _, _, _ = struct.unpack_from('<8I', binary)
    require(magic == ARM64_MAGIC and cpu == ARM64_CPU, 'not arm64 Mach-O')
    position, commands, symbol_names = 32, [], None
    for _ in range(ncmds):
        require(position + 8 <= len(binary), 'truncated load command')
        command, size = struct.unpack_from('<II', binary, position)
        require(size >= 8 and position + size <= len(binary), 'bad load command size')
        commands.append(command)
        if command == LC_SYMTAB:
            _, _, symoff, nsyms, stroff, strsize = struct.unpack_from('<6I', binary, position)
            if symoff + nsyms * 16 <= len(binary) and stroff + strsize <= len(binary):
                names = []
                for index in range(nsyms):
                    strx = struct.unpack_from('<I', binary, symoff + index * 16)[0]
                    if strx >= strsize:
                        continue
                    end = binary.find(b'\0', stroff + strx)
                    if end < 0:
                        continue
                    names.append(binary[stroff + strx:end].decode('utf-8', 'replace'))
                symbol_names = names
        position += size
    return commands, symbol_names


def require_p0_gateway_symbol(binary, symbol_names):
    hits = [name for name in (symbol_names or ())
            if GATEWAY_SYMBOL_OWNER in name
            and any(candidate in name for candidate in GATEWAY_SYMBOL_NAMES)]
    if not hits:
        # A stripped LC_SYMTAB still leaves the mangled name in the binary, so
        # fall back to a byte search instead of failing a correctly built IPA.
        hits = [marker.decode() for marker in GATEWAY_SYMBOL_MARKERS if marker in binary]
    require(hits, 'P0 gateway fix missing: no GatewayEventMap.rawEventName symbol '
            'in the Mach-O, so this package predates the SSE event-name decoder')


def check_build_info(path, version, build, info):
    require(path.is_file(), f'build-info.json not found: {path}')
    data = json.loads(path.read_text(encoding='utf-8-sig'))
    require(isinstance(data, dict), 'build-info.json is not a JSON object')
    require(str(data.get('version')) == version,
            f'build-info.json version {data.get("version")!r} != {version!r}')
    require(str(data.get('build')) == build,
            f'build-info.json build {data.get("build")!r} != {build!r}')
    require(str(data.get('working_tree')) == 'clean',
            f'build-info.json working_tree {data.get("working_tree")!r} != "clean"')
    head = str(data.get('head_commit') or '').strip()
    require(head, 'build-info.json has no head_commit')
    plist_sha = info.get('HermesGitSHA')
    if plist_sha is not None:
        require(str(plist_sha).strip() == head,
                f'Info.plist HermesGitSHA {plist_sha!r} != build-info.json '
                f'head_commit {head!r}')
    return {
        'path': str(path),
        'head_commit': head,
        'working_tree': str(data.get('working_tree')),
        'built_at': data.get('built_at'),
        'info_plist_git_sha': None if plist_sha is None else str(plist_sha),
    }


def main():
    positional, options = parse_args(sys.argv[1:])
    ipa = Path(positional[0])
    version, build = positional[1], positional[2]
    label, delivery = options['label'], options['delivery']
    require(ipa.is_file(), f'IPA not found: {ipa}')

    build_info_path = Path(positional[3]) if len(positional) == 4 else None
    if build_info_path is None and not options['no-build-info']:
        for candidate in (ipa.parent / 'build-info.json', Path.cwd() / 'build-info.json'):
            if candidate.is_file():
                build_info_path = candidate
                break
    require(build_info_path is not None or options['no-build-info'],
            'build-info.json is required: pass it as the 4th argument or place it '
            'next to the IPA (use --no-build-info only for the in-container pre-download step)')

    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        plists = [n for n in names
                  if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('/Info.plist')]
        require(len(plists) == 1, f'expected one Payload/*.app/Info.plist, got {plists}')
        app = plists[0].rsplit('/', 1)[0] + '/'
        info = plistlib.loads(archive.read(plists[0]))
        require(info.get('CFBundleIdentifier') == 'com.whale7.hermes',
                f'unexpected bundle id {info.get("CFBundleIdentifier")!r}')
        require(info.get('CFBundleShortVersionString') == version,
                f'version {info.get("CFBundleShortVersionString")!r} != {version!r}')
        require(info.get('CFBundleVersion') == build,
                f'build {info.get("CFBundleVersion")!r} != {build!r}')
        require(info.get('MinimumOSVersion') == '18.0',
                f'MinimumOSVersion {info.get("MinimumOSVersion")!r} != "18.0"')

        binary = archive.read(app + info['CFBundleExecutable'])
        commands, symbol_names = inspect_macho(binary)
        require(LC_CODE_SIGNATURE not in commands, 'LC_CODE_SIGNATURE present')
        require(not any('/_CodeSignature/' in n or n.endswith('/embedded.mobileprovision')
                        for n in names), 'signature or provisioning profile present')
        require_p0_gateway_symbol(binary, symbol_names)

        # Our own sources/tests/config must never ship. Third-party .bundle
        # resources (e.g. SwiftUIMath's build-time font-table script) are
        # expected and allowed.
        def is_own_source(n):
            relative = n[len(app):]
            if relative.startswith(('Sources/', 'tests/')):
                return True
            return n.endswith(('.swift', '.env', '.xcconfig', 'Package.resolved'))

        leaked = [n for n in names if is_own_source(n)]
        require(not leaked, f'own source/test/config leaked: {leaked[:5]}')

        for n in names:
            if (n.endswith(('.json', '.plist', '.txt', '.py', '.js', '.md'))
                    and archive.getinfo(n).file_size < 2_000_000):
                body = archive.read(n)
                for marker in SECRET_MARKERS:
                    require(marker not in body, f'secret marker {marker!r} found in {n}')

        for required in ('AppIcon60x60@2x.png', 'AppIcon60x60@3x.png',
                         'THIRD_PARTY_NOTICES.txt', 'textual_Textual.bundle/prism-bundle.js'):
            require(app + required in names, f'missing {required}')
        require(any('mathFonts.bundle/' in n and n.endswith('.otf') for n in names),
                'text engine fonts missing')
        require(any(n.endswith('GUST-FONT-LICENSE.txt') for n in names), 'font license missing')

    build_info = None
    if build_info_path is not None:
        build_info = check_build_info(build_info_path, version, build, info)

    raw = ipa.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    # F-42: "ipa" is the delivery-relative name so a reviewer can re-run this
    # script from the delivery directory, while container_path keeps the path
    # the artifact had inside the build container.
    report_ipa = label or str(ipa)
    if delivery is not None:
        delivered = Path(delivery)
        require(delivered.is_file(), f'delivered copy not found: {delivered}')
        delivered_raw = delivered.read_bytes()
        delivered_digest = hashlib.sha256(delivered_raw).hexdigest()
        require(delivered_digest == digest,
                f'delivered copy {delivered} does not match the built IPA '
                f'({delivered_digest} != {digest})')
        # --label wins so the report keeps the delivery-relative name even when
        # the caller also points at the copy it just wrote.
        report_ipa = label or str(delivered)
        digest, ipa_bytes = delivered_digest, len(delivered_raw)
    else:
        ipa_bytes = len(raw)

    print(json.dumps({
        'ipa': report_ipa,
        'container_path': str(ipa),
        'sha256': digest,
        'bundle': info['CFBundleIdentifier'],
        'version': info['CFBundleShortVersionString'],
        'build': info['CFBundleVersion'],
        'min_os': info.get('MinimumOSVersion'),
        'arch': 'arm64',
        'unsigned': True,
        'p0_gateway_symbol': 'rawEventName',
        'build_info': build_info,
        'binary_bytes': len(binary),
        'ipa_bytes': ipa_bytes,
    }, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, struct.error, zipfile.BadZipFile) as error:
        print(f'IPA_VERIFICATION_FAILED: {error}', file=sys.stderr)
        sys.exit(1)
