#!/usr/bin/env bash
# F-29: measure how far the iOS release build is from bit-for-bit reproducible.
#
# THIS IS A QUANTIFICATION TOOL, NOT A GATE. It is deliberately kept out of
# scripts/release-local.sh and out of the release pipeline: a full build takes
# far too long to run on every release, and the expected result is "not
# identical yet" (see below). Run it by hand when you want to know whether a
# change to the packaging or compiler flags moved the needle.
#
# Usage:
#   bash scripts/repro-check.sh [commit] [--keep]
#
#   commit   revision to build twice; defaults to HEAD. Must be checked out
#            already -- this script never checks anything out, because the
#            release build must run in a real PTY inside ios-build and the
#            source tree there is not a git checkout.
#   --keep   keep the scratch directory (IPAs and unpacked trees) for
#            inspection instead of deleting it on exit.
#
# What it does:
#   1. run the full release build twice from the same tree;
#   2. compare the two .ipa files by sha256;
#   3. if they differ, unpack both and diff file by file, reporting which
#      entries differ and the first differing byte offset inside each.
#
# Expected outcome today: the two IPAs differ. The Swift binaries embed
# absolute build paths that carry a per-build GUID, so the Mach-O payload is
# never byte-identical; ZIP entry order and timestamps are normalised already
# (SOURCE_DATE_EPOCH plus tar --mtime in build-on-9.ps1). Making the binaries
# match needs -Xfrontend -debug-prefix-map (or equivalent) plus a fixed build
# directory. Until then this script's job is to say *which layer* is unstable:
# if the report only lists binaries, the remaining drift is compiler-side; if it
# also lists resources, the packaging step regressed.
set -euo pipefail
ulimit -c 0
cd "$(dirname "$0")/.."

keep=0
commit=''
for arg in "$@"; do
  case $arg in
    --keep) keep=1 ;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)
      echo "unknown option: $arg (try --help)" >&2
      exit 2
      ;;
    *)
      if [[ -n $commit ]]; then
        echo 'only one commit argument is accepted' >&2
        exit 2
      fi
      commit=$arg
      ;;
  esac
done
commit=${commit:-HEAD}

for tool in git python3 sha256sum cmp; do
  if ! command -v "$tool" >/dev/null; then
    echo "MISSING_TOOL=$tool" >&2
    exit 2
  fi
done

# The two builds must see identical bytes, so the tree has to be clean and
# already sitting on the requested revision. Refusing here is better than
# silently comparing two different commits and calling the result drift.
head_sha=$(git rev-parse HEAD)
if ! target_sha=$(git rev-parse --verify --quiet "${commit}^{commit}"); then
  echo "not a known commit: $commit" >&2
  exit 2
fi
if [[ $head_sha != "$target_sha" ]]; then
  echo "HEAD is $head_sha but $commit resolves to $target_sha." >&2
  echo 'Check out that revision first; this script does not switch revisions.' >&2
  exit 2
fi
if [[ -n $(git status --porcelain) ]]; then
  echo 'Working tree is dirty; commit or stash before measuring reproducibility.' >&2
  exit 2
fi
short_sha=$(git rev-parse --short=12 "$target_sha")

if [[ ! -f release.json ]]; then
  echo 'release.json not found (single source of truth for version/build).' >&2
  exit 2
fi
# Same read as release-local.sh: no fallback, so a broken file fails here too.
if ! release_info=$(python3 - release.json <<'PY'
import json
import sys
with open(sys.argv[1], encoding='utf-8') as handle:
    data = json.load(handle)
for name in ('version', 'build'):
    value = data.get(name)
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f'release.json needs a non-empty string "{name}"')
print(data['version'].strip())
print(data['build'].strip())
PY
); then
  echo 'release.json is invalid.' >&2
  exit 2
fi
release_version=${release_info%%$'\n'*}
release_build=${release_info##*$'\n'}
ipa_name="Hermes-$release_version-build$release_build-unsigned.ipa"
ipa_path="releases/$ipa_name"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/hermes-repro-XXXXXXXX")
cleanup() {
  if (( keep )); then
    echo "Scratch kept: $scratch" >&2
  else
    rm -rf "$scratch"
  fi
}
trap cleanup EXIT

# The release build refuses a duplicate version+build, and it writes into
# releases/ in place. Move the first IPA aside so the second run is allowed,
# and so the two artifacts cannot be confused with each other.
build_once() {
  local label=$1 destination=$2
  echo "=== build $label: $release_version / build$release_build @ $short_sha ===" >&2
  # release-local.sh needs a PTY (xtool requirement); call it the same way the
  # release path does and let its own guards report a missing TTY.
  if ! bash scripts/release-local.sh; then
    echo "BUILD_FAILED run=$label" >&2
    echo 'This must run where swiftc and xtool exist, i.e. inside the ios-build' >&2
    echo 'container under a real PTY (ssh -tt ... docker exec -t). A bare host' >&2
    echo 'shell fails the pre-flight with MISSING_BUILD_TOOL.' >&2
    return 1
  fi
  if [[ ! -f $ipa_path ]]; then
    echo "BUILD_PRODUCED_NO_IPA run=$label expected=$ipa_path" >&2
    return 1
  fi
  mv "$ipa_path" "$destination"
  echo "captured $label -> $destination" >&2
}

first=$scratch/first.ipa
second=$scratch/second.ipa
build_once first "$first"
build_once second "$second"

sha_first=$(sha256sum "$first" | cut -d' ' -f1)
sha_second=$(sha256sum "$second" | cut -d' ' -f1)
size_first=$(wc -c < "$first")
size_second=$(wc -c < "$second")

echo "commit=$target_sha"
echo "version=$release_version build=$release_build"
echo "first:  sha256=$sha_first size=$size_first"
echo "second: sha256=$sha_second size=$size_second"

if [[ $sha_first == "$sha_second" ]]; then
  echo 'REPRO_IDENTICAL two builds produced the same IPA'
  exit 0
fi

echo 'REPRO_DRIFT the two IPAs differ; diffing their contents'
echo "sizes: $size_first vs $size_second (delta $((size_second - size_first)))"

# Unpack with python3: the slim ios-build image has no unzip, and bsdtar is only
# guaranteed on the packaging side.
unpack() {
  local archive=$1 destination=$2
  mkdir -p "$destination"
  python3 - "$archive" "$destination" <<'PY'
import sys
import zipfile
with zipfile.ZipFile(sys.argv[1]) as bundle:
    bundle.extractall(sys.argv[2])
PY
}
dir_first=$scratch/tree-first
dir_second=$scratch/tree-second
unpack "$first" "$dir_first"
unpack "$second" "$dir_second"

python3 - "$dir_first" "$dir_second" "$(command -v cmp || true)" <<'PY'
import hashlib
import subprocess
import sys
from pathlib import Path

first_root, second_root = Path(sys.argv[1]), Path(sys.argv[2])
cmp_path = sys.argv[3] if len(sys.argv) > 3 else ''


def inventory(root):
    return {
        path.relative_to(root).as_posix(): path
        for path in root.rglob('*') if path.is_file()
    }


first, second = inventory(first_root), inventory(second_root)
only_first = sorted(first.keys() - second.keys())
only_second = sorted(second.keys() - first.keys())
common = sorted(first.keys() & second.keys())

# Mach-O magic (both endiannesses, 32/64-bit, fat) marks a compiled binary. The
# distinction matters: binary drift means the compiler/toolchain layer is
# unstable, resource drift means the packaging layer is.
MACHO_MAGICS = {
    b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe',
    b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce',
    b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
}


def is_binary(path):
    with path.open('rb') as handle:
        return handle.read(4) in MACHO_MAGICS


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


differing_binaries, differing_resources = [], []
for name in common:
    left, right = first[name], second[name]
    if digest(left) == digest(right):
        continue
    entry = {'name': name, 'size': (left.stat().st_size, right.stat().st_size)}
    (differing_binaries if is_binary(left) or is_binary(right)
     else differing_resources).append(entry)

for name in only_first:
    differing_resources.append({'name': name, 'size': (first[name].stat().st_size, 0),
                                'note': 'only in first'})
for name in only_second:
    differing_resources.append({'name': name, 'size': (0, second[name].stat().st_size),
                                'note': 'only in second'})

print(f'entries: {len(common)} common, {len(only_first)} only-first, '
      f'{len(only_second)} only-second')
print(f'differing binaries:  {len(differing_binaries)}')
print(f'differing resources: {len(differing_resources)}')

for label, entries in (('BINARY', differing_binaries), ('RESOURCE', differing_resources)):
    for entry in entries:
        note = f" ({entry['note']})" if 'note' in entry else ''
        print(f"{label}\t{entry['name']}\t{entry['size'][0]}B vs "
              f"{entry['size'][1]}B{note}")

# Offset report uses cmp, as the backlog entry asks, so the number is
# reproducible outside this script. Plain `cmp` (not `-l`) is used on purpose:
# -l lists every differing byte, which on a 100 MB Mach-O with a shifted string
# table is tens of millions of lines. Plain cmp stops at the first difference
# and prints "byte N", which is exactly the number wanted.
if differing_binaries or differing_resources:
    print('--- first differing byte per file (cmp, 1-based offset) ---')
    for entry in differing_binaries + differing_resources:
        name = entry['name']
        if 'note' in entry or name not in first or name not in second:
            print(f'OFFSET\t{name}\t(n-a: file exists in only one build)')
            continue
        left, right = first[name], second[name]
        offset = None
        if cmp_path:
            result = subprocess.run([cmp_path, str(left), str(right)],
                                    capture_output=True, text=True)
            combined = (result.stdout or '') + (result.stderr or '')
            # "a b differ: byte 7, line 1" for a real difference.
            if 'differ: byte ' in combined:
                digits = combined.split('differ: byte ', 1)[1].split(',')[0]
                if digits.strip().isdigit():
                    offset = int(digits.strip())
            # "cmp: EOF on 'a' after byte 4" when one file is a prefix of the
            # other, so the first difference is the first byte past the shorter.
            elif 'EOF on' in combined and 'after byte ' in combined:
                tail = combined.split('after byte ', 1)[1].split(',')[0]
                if tail.strip().isdigit():
                    offset = int(tail.strip()) + 1
        if offset is None:
            a, b = left.read_bytes(), right.read_bytes()
            for index, (x, y) in enumerate(zip(a, b)):
                if x != y:
                    offset = index + 1
                    break
            if offset is None and len(a) != len(b):
                offset = min(len(a), len(b)) + 1
        print(f'OFFSET\t{name}\t{offset if offset is not None else "unknown"}')

    print('--- verdict ---')
    if differing_binaries and not differing_resources:
        print('drift is confined to compiled binaries: compiler-side absolute '
              'paths/GUIDs. Packaging is stable; -debug-prefix-map is the fix.')
    elif differing_resources and not differing_binaries:
        print('drift is confined to resources: the packaging step regressed '
              '(timestamps, entry order or generated files).')
    else:
        print('drift affects both binaries and resources: fix packaging first, '
              'then re-measure to isolate the compiler contribution.')
PY

exit 0
