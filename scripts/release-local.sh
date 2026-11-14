#!/usr/bin/env bash
# Run in the existing xtool/Apple SDK container, from a real PTY.
set -euo pipefail
ulimit -c 0
cd "$(dirname "$0")/.."
for tool in swiftc xtool python3 sha256sum; do
  if ! command -v "$tool" >/dev/null; then
    echo "MISSING_BUILD_TOOL=$tool" >&2
    exit 2
  fi
done
if [[ ! -t 0 || ! -t 1 ]]; then
  echo 'xtool needs a PTY: use ssh -tt and docker exec -t.' >&2
  exit 2
fi
if ! command -v flock >/dev/null; then
  echo 'Missing flock; install util-linux in the build environment.' >&2
  exit 2
fi
# F-41: the release number comes from release.json and nowhere else. There is
# deliberately no fallback: a missing or malformed file must stop the release
# instead of producing a package whose number disagrees with the source gate.
if [[ ! -f release.json ]]; then
  echo 'release.json not found at the repository root (single source of truth).' >&2
  exit 2
fi
if ! release_info=$(python3 - release.json <<'PY'
import json
import sys
try:
    with open(sys.argv[1], encoding='utf-8') as handle:
        data = json.load(handle)
except (OSError, ValueError) as error:
    raise SystemExit(f'release.json unreadable: {error}')
version, build = data.get('version'), data.get('build')
for name, value in (('version', version), ('build', build)):
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f'release.json needs a non-empty string "{name}"')
print(version.strip())
print(build.strip())
PY
); then
  echo 'release.json is invalid; the source gate would reject this build.' >&2
  exit 2
fi
release_version=${release_info%%$'\n'*}
release_build=${release_info##*$'\n'}
if [[ -z $release_version || -z $release_build || $release_build == "$release_info" ]]; then
  echo 'release.json did not yield exactly two lines (version, build).' >&2
  exit 2
fi
exec 9>/work/.hermes-ios-release.lock
flock -n 9 || { echo 'Another Hermes release is running.' >&2; exit 2; }
# The existing slim image has no procps/pgrep. Inspect argv using its installed
# Python instead of silently skipping the overlap guard or changing the image.
python3 - <<'PY'
from pathlib import Path
import sys
for path in Path('/proc').glob('[0-9]*/cmdline'):
    try:
        argv = path.read_bytes().split(b'\0')
    except (FileNotFoundError, ProcessLookupError):
        continue
    except PermissionError:
        raise SystemExit('Cannot inspect active builds safely.')
    if not argv or not argv[0]:
        continue
    executable = Path(argv[0].decode(errors='replace')).name
    args = [value.decode(errors='replace') for value in argv[1:] if value]
    if executable == 'swift-build' or (executable == 'xtool' and any(
        args[index:index+2] == ['dev', 'build'] for index in range(len(args)-1))):
        print('An existing build is active; retry after it finishes.', file=sys.stderr)
        raise SystemExit(2)
PY
# The workspace is now a fixed directory that survives between releases, so
# `releases/` may still hold the previous run's artifacts. Clear it first:
# otherwise the duplicate guard below would refuse every rebuild of the same
# version, and SHA256SUMS would hash a stale IPA alongside the new one.
# Only `releases/` is cleared -- `.build/` must survive for incremental builds.
if [[ -d releases ]]; then
  find releases -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
fi
mkdir -p releases
# The fixed workspace is written by the host user over rsync but built as root
# here, so git refuses the dependency caches under .build/repositories with
# 'detected dubious ownership'. SwiftPM then treats them as unusable, falls back
# to fetching from the network, and this container has no route to github.com --
# the build dies after a ~135s connect timeout instead of compiling.
# Taking ownership and registering the safe directory is what makes the cached
# .build/ actually reusable. Only the workspace root is re-owned, and only when
# it is not already owned by the current user, so the common case is a no-op.
if [[ "$PWD" != /work/HermesShell ]]; then
  if [[ -d .git || -d .build ]]; then
    if [[ ! -w . || -n $(find . -maxdepth 1 ! -user "$(id -u)" -print -quit 2>/dev/null) ]]; then
      chown -R "$(id -u):$(id -g)" . 2>/dev/null || true
    fi
  fi
  git config --global --add safe.directory "$PWD" 2>/dev/null || true
  # Dependency checkouts are bare git repos too; register each one so SwiftPM
  # never needs to re-clone (which it cannot do offline).
  if [[ -d .build/repositories ]]; then
    for repo in .build/repositories/*; do
      [[ -d "$repo" ]] || continue
      git config --global --add safe.directory "$PWD/$repo" 2>/dev/null || true
    done
  fi
fi
# Reuse only copied dependency source caches; never share mutable build outputs
# or change the original /work/HermesShell directory.
if [[ "$PWD" != /work/HermesShell && ! -e .build ]]; then
  mkdir .build
  for cache in repositories checkouts; do
    if [[ -d /work/HermesShell/.build/$cache && ! -L /work/HermesShell/.build/$cache ]]; then
      cp -a "/work/HermesShell/.build/$cache" .build/
    fi
  done
fi

name="Hermes-$release_version-build$release_build-unsigned"
failed_log=releases/FAILED.txt
scratch=$(mktemp -d)
current_step='init'
current_log=''

# F-30/P2-19: a failed run must leave a diagnosis behind, and a leftover
# 0-file directory must not block the next run. The EXIT trap covers failures
# that happen after the pre-flight guards, including the explicit `exit 1`
# branches below.
on_exit() {
  local status=$?
  # Only a real build failure is reported. The pre-flight refusals (missing
  # tool, no PTY, lock held, duplicate output) leave current_step at 'init';
  # they are not a failed build and must not drop a FAILED.txt that would
  # outlive the retry.
  if (( status != 0 )) && [[ $current_step != init ]] && [[ -d releases ]]; then
    {
      printf 'status=FAILED\n'
      printf 'step=%s\n' "$current_step"
      printf 'exit_code=%d\n' "$status"
      printf 'failed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      if [[ -n "$current_log" && -f "$current_log" ]]; then
        printf 'log=%s\n' "$current_log"
        printf -- '--- tail -40 %s ---\n' "$current_log"
        tail -n 40 "$current_log" || true
      else
        printf 'log=(no step output captured)\n'
      fi
    } > "$failed_log"
    printf 'RELEASE_FAILED step=%s exit=%d details=%s\n' \
      "$current_step" "$status" "$failed_log" >&2
  fi
  if [[ -n "$scratch" && -d "$scratch" ]]; then rm -rf "$scratch"; fi
  # Only empty top-level directories: files (including FAILED.txt) and the
  # archive/ directory are never touched.
  if [[ -d releases ]]; then
    find releases -mindepth 1 -maxdepth 1 -type d -empty ! -name archive -delete 2>/dev/null || true
  fi
}
trap on_exit EXIT

# Run one release step with its own artifact log. `set -e` plus `pipefail`
# abort the script on the first failure, and the EXIT trap records which step.
step() {
  local label=$1 log=$2
  shift 2
  current_step=$label
  current_log=$log
  "$@" 2>&1 | tee "$log"
}

# Drop a stale marker from an earlier attempt so a success is never accompanied
# by an old FAILED.txt.
rm -f "$failed_log"

# F-30: refuse a duplicate version+build. Artifacts land in releases/ inside the
# container but in releases/<task>-<sha>-<stamp>/ on the delivery host, so both
# layouts are checked instead of only the flat one.
duplicate=''
for candidate in "releases/$name.ipa" releases/*/"$name.ipa"; do
  if [[ -e "$candidate" ]]; then
    duplicate="$candidate${duplicate:+ $duplicate}"
  fi
done
if [[ -n "$duplicate" ]]; then
  echo "This release output already exists ($duplicate); use a new isolated directory." >&2
  exit 2
fi

# The Actions release path defers complete source/offline regression until AFTER
# the official Release and Bark notification. Direct/manual builds retain the
# original full suite by default. Neither mode bypasses IPA verification.
case "${HERMES_CI_COMPILE_ONLY:-0}" in
  0)
    step 'source gate' releases/source-check.json python3 tests/verify_source.py
    ;;
  1)
    echo "POST_RELEASE_SOURCE_GATE=DEFERRED"
    ;;
  *)
    echo "::error::HERMES_CI_COMPILE_ONLY must be 0 or 1" >&2
    exit 2
    ;;
esac
step 'toolchain (swift)' releases/toolchain.txt swift --version
current_step='toolchain (xtool)'
current_log=releases/toolchain.txt
xtool --version 2>&1 | tee -a releases/toolchain.txt
# Complete offline regression is a post-release task for the Actions flow.
# Standalone/manual builds keep the historical full regression by default.
if [[ "${HERMES_CI_COMPILE_ONLY:-0}" == "1" ]]; then
  echo "POST_RELEASE_OFFLINE_REGRESSIONS=DEFERRED"
elif [[ "${HERMES_CI_DETACH_TESTS:-}" == "1" ]]; then
  current_step='container tests'
  current_log=releases/tests.txt
  setsid bash tests/run_container.sh < /dev/null 2>&1 | tee "$current_log"
else
  step 'container tests' releases/tests.txt bash tests/run_container.sh
fi
step 'xtool dev build' releases/build.txt xtool dev build --configuration release --ipa

current_step='copy IPA to delivery directory'
current_log="$scratch/copy.log"
cp -v xtool/HermesShell.ipa "releases/$name.ipa" > "$current_log" 2>&1 || {
  cat "$current_log" >&2
  exit 1
}
cat "$current_log"

# F-42/F-81: verify the delivered copy, not just the container output, and keep
# both paths in the report. `ipa` is the delivery-relative name so a reviewer
# can re-run this script from the delivery directory; `container_path` keeps the
# build-container path. build-info.json does not exist yet at this point (it is
# written by build-on-9.ps1 only after a successful build), so --no-build-info
# skips exactly that one check here; build-on-9.ps1 then enforces it on the
# downloaded copy before sealing the release.
current_step='IPA verification'
current_log="$scratch/verify.log"
if python3 tests/verify_ipa.py xtool/HermesShell.ipa "$release_version" "$release_build" \
     --no-build-info --delivery "releases/$name.ipa" --label "$name.ipa" \
     > "$scratch/validation.json" 2> "$current_log"; then
  mv "$scratch/validation.json" releases/validation.json
  cat releases/validation.json
  printf '\n'
else
  cat "$current_log" >&2
  exit 1
fi

# F-65: cover every release file, not just the IPA, so a truncated log or a
# swapped validation.json is detectable. build-info.json is added by
# build-on-9.ps1, which rewrites this file after the download.
current_step='SHA256SUMS'
current_log="$scratch/sums.log"
files=()
for path in releases/*; do
  [[ -f "$path" ]] || continue
  base=${path##*/}
  case $base in
    SHA256SUMS.txt|FAILED.txt) continue ;;
  esac
  files+=("$base")
done
if (( ${#files[@]} == 0 )); then
  echo 'No release files to hash.' >&2
  exit 1
fi
( cd releases && sha256sum "${files[@]}" ) > "$scratch/SHA256SUMS.txt" 2> "$current_log" || {
  cat "$current_log" >&2
  exit 1
}
mv "$scratch/SHA256SUMS.txt" releases/SHA256SUMS.txt
cat releases/SHA256SUMS.txt

echo "RELEASE_IPA_READY releases/$name.ipa"
