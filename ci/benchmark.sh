#!/usr/bin/env bash
# Independent GitHub-macOS benchmark. Never publishes IPA or runs 9th runner.
set -euo pipefail
SOURCE_SHA="1e57404cae21f567a67d4e2ce92276c101642908"
DERIVED="$RUNNER_TEMP/hermes-ipa-derived"
ENCRYPTED="$RUNNER_TEMP/hermes-cache.enc"
COMPRESSED="$RUNNER_TEMP/hermes-cache.tar.zst"
CRYPTO="$GITHUB_WORKSPACE/tooling/ci/cache-crypto.mjs"
SRC="$GITHUB_WORKSPACE/src"
now() { python3 -c 'import time; print(time.monotonic_ns())'; }
elapsed() { python3 - "$1" "$2" <<'PY'
import sys
print(f'{(int(sys.argv[2])-int(sys.argv[1])) / 1e9:.3f}')
PY
}
out() { printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; }

case "${1:-}" in
  prepare)
    sudo xcode-select -s /Applications/Xcode_26.3.app/Contents/Developer
    [[ "$(xcodebuild -version | awk '/^Xcode / {print $2; exit}')" == "26.3" ]]
    [[ "$(xcrun --sdk iphoneos --show-sdk-version)" == "26.2" ]]
    command -v node >/dev/null
    command -v zstd >/dev/null
    if ! command -v xcodegen >/dev/null; then
      brew install xcodegen >"$RUNNER_TEMP/hermes-brew-install.log" 2>&1
    fi
    [[ "$(git -C "$SRC" rev-parse HEAD)" == "$SOURCE_SHA" ]]
    python3 - "$SRC/release.json" <<'PY'
import json, sys
release = json.load(open(sys.argv[1]))
assert release['version'] == '2.24.0' and release['build'] == '162'
PY
    echo "BENCH_PREPARE_OK xcode=26.3 ios_sdk=26.2"
    ;;
  build)
    phase="${2:?cold|warm required}"
    wrapper_dir="$RUNNER_TEMP/hermes-xcode-wrapper"
    tooling_dir="$GITHUB_WORKSPACE/tooling"
    mkdir -p "$wrapper_dir"
    cat >"$wrapper_dir/xcodebuild" <<'SH'
#!/usr/bin/env bash
exec bash "$HERMES_TOOLING_DIR/ci/xcodebuild-diagnostic-wrapper.sh" "$@"
SH
    chmod 700 "$wrapper_dir/xcodebuild"
    start="$(now)"
    set +e
    ( cd "$SRC" && PATH="$wrapper_dir:$PATH" HERMES_TOOLING_DIR="$tooling_dir" HERMES_BENCH_PHASE="$phase" \
      GITHUB_WORKSPACE="$PWD" PR_HEAD_SHA="$SOURCE_SHA" \
      bash scripts/github-build-ipa.sh >"$RUNNER_TEMP/hermes-build-${phase}.log" 2>&1 )
    rc=$?
    set -e
    finish="$(now)"
    duration="$(elapsed "$start" "$finish")"
    out build_seconds "$duration"
    if [[ "$rc" -ne 0 ]]; then
      echo "::error::Xcode build/IPA verification failed. Private compiler logs not uploaded."
      exit "$rc"
    fi
    metrics="$RUNNER_TEMP/hermes-${phase}-build-log.json"
    settings="$RUNNER_TEMP/hermes-${phase}-build-settings.txt"
    if [[ -s "$metrics" ]]; then
      python3 "$GITHUB_WORKSPACE/tooling/ci/summarize-xcode-build.py" "$phase" "$metrics" "$settings"
    else
      echo "XCODE_ACTIVITY_METRICS=unavailable"
    fi
    rm -f "$metrics" "$settings" "$RUNNER_TEMP/hermes-$phase-xcresulttool.stderr"
    rm -rf "$RUNNER_TEMP/hermes-$phase.xcresult"
    python3 - "$SRC/release/validation.json" "$GITHUB_OUTPUT" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
assert v['version'] == '2.24.0' and v['build'] == '162'
assert v['bundle'] == 'com.whale7.hermes' and v['arch'] == 'arm64' and v['unsigned'] is True
with open(sys.argv[2], 'a') as f:
    f.write(f"ipa_sha={v['sha256']}\nipa_bytes={v['ipa_bytes']}\n")
print('IPA_VERIFIED bytes=' + str(v['ipa_bytes']))
PY
    echo "BENCH_${phase}_BUILD_SECONDS=$duration"
    ;;
  pack)
    [[ -d "$DERIVED/Build" ]] || { echo '::error::DerivedData Build missing'; exit 1; }
    echo "DERIVEDDATA_KIB=$(du -sk "$DERIVED" | awk '{print $1}')"
    start="$(now)"
    tar -C "$RUNNER_TEMP" -cf - hermes-ipa-derived | zstd -T0 -1 -q -o "$COMPRESSED"
    finished="$(now)"
    duration="$(elapsed "$start" "$finished")"
    out compress_seconds "$duration"
    echo "CACHE_COMPRESS_SECONDS=$duration"
    echo "COMPRESSED_BYTES=$(stat -f %z "$COMPRESSED")"
    start="$(now)"
    node "$CRYPTO" encrypt "$COMPRESSED" "$ENCRYPTED"
    finished="$(now)"
    duration="$(elapsed "$start" "$finished")"
    out encrypt_seconds "$duration"
    bytes="$(stat -f %z "$ENCRYPTED")"
    [[ "$bytes" -lt 3221225472 ]] || { echo '::error::Cache exceeds 3 GiB benchmark safety cap'; exit 1; }
    out encrypted_bytes "$bytes"
    rm -f "$COMPRESSED"
    echo "CACHE_ENCRYPT_SECONDS=$duration ENCRYPTED_BYTES=$bytes"
    ;;
  unpack)
    [[ -s "$ENCRYPTED" ]] || { echo '::error::Encrypted cache is missing'; exit 1; }
    start="$(now)"
    node "$CRYPTO" decrypt "$ENCRYPTED" "$COMPRESSED"
    finished="$(now)"
    duration="$(elapsed "$start" "$finished")"
    out decrypt_seconds "$duration"
    echo "CACHE_DECRYPT_SECONDS=$duration"
    start="$(now)"
    zstd -dc -q "$COMPRESSED" | tar -C "$RUNNER_TEMP" -xf -
    finished="$(now)"
    duration="$(elapsed "$start" "$finished")"
    [[ -d "$DERIVED/Build" ]] || { echo '::error::Cache contents invalid'; exit 1; }
    rm -f "$COMPRESSED"
    out extract_seconds "$duration"
    echo "CACHE_DECOMPRESS_SECONDS=$duration"
    ;;
  timer-start)
    out ns "$(now)"
    ;;
  timer-stop)
    duration="$(elapsed "${START_NS:?}" "$(now)")"
    out seconds "$duration"
    echo "CACHE_${2:-TRANSFER}_SECONDS=$duration"
    ;;
  report)
    python3 - <<'PY'
import os
v = os.environ
n = lambda name: float(v[name])
cold, warm = n('COLD_BUILD'), n('WARM_BUILD')
write = n('COMPRESS') + n('ENCRYPT') + n('UPLOAD')
read = n('DOWNLOAD') + n('DECRYPT') + n('EXTRACT')
warm_total = warm + read
net_two = cold - write - warm_total
same_sha = v['COLD_SHA'] == v['WARM_SHA']
summary = '\n'.join([
    '## build162 encrypted DerivedData benchmark',
    '',
    '| Measured stage | Seconds |',
    '|---|---:|',
    f'| Cold Xcode compile + IPA verification | {cold:.3f} |',
    f'| Compress DerivedData (zstd -1 multithread) | {n("COMPRESS"):.3f} |',
    f'| Encrypt AES-256-GCM | {n("ENCRYPT"):.3f} |',
    f'| Cache upload | {n("UPLOAD"):.3f} |',
    f'| Cache download | {n("DOWNLOAD"):.3f} |',
    f'| Decrypt AES-256-GCM | {n("DECRYPT"):.3f} |',
    f'| Decompress / extract | {n("EXTRACT"):.3f} |',
    f'| Warm Xcode compile + IPA verification | {warm:.3f} |',
    f'| **Warm restore + compile total** | **{warm_total:.3f}** |',
    f'| **Net saving over two builds (including cache write)** | **{net_two:+.3f}** |',
    '',
    f'- Encrypted cache: {v["ENCRYPTED_BYTES"]} bytes',
    f'- Cold IPA: {v["COLD_BYTES"]} bytes',
    f'- Warm IPA: {v["WARM_BYTES"]} bytes',
    f'- IPA SHA-256 identical: {same_sha}',
    f'- Cold SHA256: {v["COLD_SHA"]}',
    f'- Warm SHA256: {v["WARM_SHA"]}',
    '- Private source, IPA and compiler logs were NOT uploaded to public artifacts or Releases.',
    '- Original 9th runner and private HermesShell Release were NOT modified.',
]) + '\n'
print(summary)
with open(v['GITHUB_STEP_SUMMARY'], 'a') as f:
    f.write(summary)
PY
    ;;
  *) echo 'Usage: benchmark.sh prepare|build cold|warm|pack|unpack|timer-start|timer-stop|report' >&2; exit 2 ;;
esac
