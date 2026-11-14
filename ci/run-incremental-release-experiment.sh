#!/usr/bin/env bash
# Isolated build162 experiment: compare Release WMO and Incremental while
# keeping -O, the pinned source commit, Xcode/SDK and runner constant.
# No source content is changed; the probe only touches AppTheme.swift.
set -euo pipefail

SOURCE_SHA="1e57404cae21f567a67d4e2ce92276c101642908"
TOOLING="$GITHUB_WORKSPACE/tooling"

prepare() {
  sudo xcode-select -s /Applications/Xcode_26.3.app/Contents/Developer
  [[ "$(xcodebuild -version | awk '/^Xcode / {print $2; exit}')" == "26.3" ]] || {
    echo "::error::Expected Xcode 26.3"; exit 1;
  }
  [[ "$(xcrun --sdk iphoneos --show-sdk-version)" == "26.2" ]] || {
    echo "::error::Expected iPhoneOS SDK 26.2"; exit 1;
  }
  if ! command -v xcodegen >/dev/null 2>&1; then
    brew install xcodegen >"$RUNNER_TEMP/hermes-exp-xcodegen-install.log" 2>&1
  fi
  local xcodegen_version
  xcodegen_version="$(xcodegen --version | awk '{print $NF}')"
  python3 - "$xcodegen_version" <<'PY'
import re, sys
match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", sys.argv[1])
if not match or tuple(map(int, match.groups())) < (2, 42, 0):
    raise SystemExit("XcodeGen 2.42.0 or newer is required; got " + sys.argv[1])
PY
  printf '%s\n' "$xcodegen_version" >"$RUNNER_TEMP/hermes-exp-xcodegen-version.txt"
  for mode in wholemodule incremental; do
    local src="$GITHUB_WORKSPACE/src-$mode"
    [[ "$(git -C "$src" rev-parse HEAD)" == "$SOURCE_SHA" ]] || {
      echo "::error::Pinned source SHA mismatch for $mode"; exit 1;
    }
    [[ -z "$(git -C "$src" status --porcelain)" ]] || {
      echo "::error::Source checkout is not clean before experiment: $mode"; exit 1;
    }
    python3 "$src/tests/verify_source.py" "$src" >/dev/null
  done
  echo "EXPERIMENT_PREPARE_OK source=$SOURCE_SHA xcode=26.3 ios_sdk=26.2 xcodegen=$xcodegen_version"
}

make_wrapper() {
  local mode="$1"
  local wrapper_dir="$RUNNER_TEMP/hermes-exp-wrapper-$mode"
  mkdir -p "$wrapper_dir"
  cat >"$wrapper_dir/xcodebuild" <<'SH'
#!/usr/bin/env bash
exec bash "$HERMES_TOOLING_DIR/ci/xcodebuild-incremental-experiment-wrapper.sh" "$@"
SH
  chmod 700 "$wrapper_dir/xcodebuild"
  printf '%s' "$wrapper_dir"
}

capture_validation() {
  local mode="$1"
  local phase="$2"
  local src="$GITHUB_WORKSPACE/src-$mode"
  local validation="$src/release/validation.json"
  local metrics="$RUNNER_TEMP/hermes-exp-$mode-$phase.json"
  [[ -s "$validation" && -s "$metrics" ]] || {
    echo "::error::Missing IPA validation or Xcode timing metrics for $mode/$phase"; exit 1;
  }
  python3 - "$validation" "$metrics" "$SOURCE_SHA" <<'PY'
import json, sys
validation_path, metrics_path, expected_sha = sys.argv[1:]
validation = json.load(open(validation_path, encoding="utf-8"))
metrics = json.load(open(metrics_path, encoding="utf-8"))
assert validation["version"] == "2.24.0" and validation["build"] == "162"
assert validation["bundle"] == "com.whale7.hermes"
assert validation["arch"] == "arm64" and validation["unsigned"] is True
assert validation["build_info"]["head_commit"] == expected_sha
metrics.update({
    "ipa_sha256": validation["sha256"],
    "ipa_bytes": validation["ipa_bytes"],
    "binary_bytes": validation["binary_bytes"],
    "version": validation["version"],
    "build": validation["build"],
    "bundle": validation["bundle"],
    "arch": validation["arch"],
    "unsigned": validation["unsigned"],
    "source_commit": expected_sha,
    "ipa_verification": "passed",
})
with open(metrics_path, "w", encoding="utf-8") as output:
    json.dump(metrics, output, ensure_ascii=False, indent=2)
    output.write("\n")
print(
    f"IPA_VERIFIED mode={metrics['mode']} phase={metrics['phase']} "
    f"bytes={validation['ipa_bytes']} sha256={validation['sha256']}"
)
PY
}

clean_generated_outputs() {
  local src="$1"
  rm -rf "$src/release"
  # XcodeGen's project is required for the warm rebuild. Ignore this generated
  # project only in the disposable checkout's local Git exclude file.
  touch "$src/.git/info/exclude"
  grep -qxF 'HermesShellCI.xcodeproj/' "$src/.git/info/exclude" || \
    printf '%s\n' 'HermesShellCI.xcodeproj/' >>"$src/.git/info/exclude"
  if [[ -f "$src/Package.resolved" ]] && ! git -C "$src" diff --quiet -- Package.resolved; then
    git -C "$src" checkout -- Package.resolved
  fi
  [[ -z "$(git -C "$src" status --porcelain)" ]] || {
    echo "::error::Unexpected source checkout changes remain"
    git -C "$src" status --short
    exit 1
  }
}

run_build() {
  local mode="$1"
  local phase="$2"
  local src="$GITHUB_WORKSPACE/src-$mode"
  local derived="$RUNNER_TEMP/hermes-exp-$mode-derived"
  local wrapper_dir
  wrapper_dir="$(make_wrapper "$mode")"
  local driver_log="$RUNNER_TEMP/hermes-exp-$mode-$phase-driver.log"

  if [[ "$phase" == "cold" ]]; then
    rm -rf "$derived"
    [[ -z "$(git -C "$src" status --porcelain)" ]] || {
      echo "::error::Source tree is dirty before cold build: $mode"; exit 1;
    }
  else
    [[ -d "$derived/Build" && -d "$src/HermesShellCI.xcodeproj" ]] || {
      echo "::error::Warm DerivedData or generated project missing for $mode"; exit 1;
    }
    [[ -f "$RUNNER_TEMP/HermesCI-Info.plist" ]] || {
      echo "::error::Generated CI Info.plist missing"; exit 1;
    }
    [[ -z "$(git -C "$src" status --porcelain)" ]] || {
      echo "::error::Source tree is dirty before changed rebuild: $mode"; exit 1;
    }
  fi

  set +e
  if [[ "$phase" == "cold" ]]; then
    (
      cd "$src"
      env PATH="$wrapper_dir:$PATH" HERMES_TOOLING_DIR="$TOOLING" \
        HERMES_EXPERIMENT_MODE="$mode" HERMES_EXPERIMENT_PHASE="$phase" \
        HERMES_EXPERIMENT_DERIVED="$derived" PR_HEAD_SHA="$SOURCE_SHA" \
        bash scripts/github-build-ipa.sh
    ) >"$driver_log" 2>&1
  else
    (
      cd "$src"
      env PATH="$wrapper_dir:$PATH" HERMES_TOOLING_DIR="$TOOLING" \
        HERMES_EXPERIMENT_MODE="$mode" HERMES_EXPERIMENT_PHASE="$phase" \
        HERMES_EXPERIMENT_DERIVED="$derived" \
        xcodebuild "INFOPLIST_FILE=$RUNNER_TEMP/HermesCI-Info.plist" \
          -project HermesShellCI.xcodeproj -scheme HermesShell \
          -destination 'generic/platform=iOS' -sdk iphoneos \
          -configuration Release -derivedDataPath "$RUNNER_TEMP/hermes-ipa-derived" \
          CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO 'CODE_SIGN_IDENTITY=' \
          STRIP_INSTALLED_PRODUCT=NO COPY_PHASE_STRIP=NO build
    ) >"$driver_log" 2>&1
    local build_status=$?
    if [[ "$build_status" -eq 0 ]]; then
      local version build name app stage ipa
      version="$(python3 -c 'import json; print(json.load(open("release.json"))["version"])' 2>/dev/null)"
      build="$(python3 -c 'import json; print(json.load(open("release.json"))["build"])' 2>/dev/null)"
      name="Hermes-$version-build$build-unsigned"
      app="$derived/Build/Products/Release-iphoneos/HermesShell.app"
      ipa="$src/release/$name.ipa"
      mkdir -p "$src/release"
      if [[ ! -d "$app" || ! -f "$app/HermesShell" ]]; then
        echo "::error::iPhoneOS app missing after changed rebuild"; exit 1;
      fi
      stage="$(mktemp -d "$RUNNER_TEMP/hermes-exp-payload.XXXXXX")"
      mkdir -p "$stage/Payload"
      cp -R "$app" "$stage/Payload/HermesShell.app"
      ( cd "$stage" && zip -qry "$ipa" Payload )
      rm -rf "$stage"
      python3 - "$src/release/build-info.json" "$version" "$build" "$SOURCE_SHA" <<'PY'
import datetime, json, pathlib, sys
path, version, build, commit = sys.argv[1:]
info = {
    "version": version,
    "build": build,
    "working_tree": "clean",
    "head_commit": commit,
    "source_head_commit": commit,
    "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "builder": "github-actions-macos-15-xcode-26.3-incremental-experiment",
}
pathlib.Path(path).write_text(json.dumps(info, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
      python3 tests/verify_ipa.py "$ipa" "$version" "$build" "$src/release/build-info.json" \
        --label "$name.ipa" >"$src/release/validation.json"
    fi
    status="$build_status"
  fi
  status="${status:-$?}"
  set -e
  if [[ "$status" -ne 0 ]]; then
    echo "::error::build162 $mode/$phase failed"
    grep -E 'error:|ERROR:|SOURCE_GATE_FAILED|IPA_VERIFICATION_FAILED|XCODE_EXPERIMENT|XCODEBUILD_WALL' "$driver_log" | tail -40 || true
    exit "$status"
  fi

  capture_validation "$mode" "$phase"
  grep -E '^XCODEBUILD_WALL_SECONDS=|^XCODE_EXPERIMENT ' "$driver_log" || true
  clean_generated_outputs "$src"
  echo "EXPERIMENT_BUILD_OK mode=$mode phase=$phase"
}

touch_probe() {
  local mode="$1"
  local src="$GITHUB_WORKSPACE/src-$mode"
  local file="$src/Sources/HermesShell/AppTheme.swift"
  local before after
  before="$(shasum -a 256 "$file" | awk '{print $1}')"
  sleep 2
  touch "$file"
  after="$(shasum -a 256 "$file" | awk '{print $1}')"
  [[ "$before" == "$after" ]] || {
    echo "::error::Probe changed source content for $mode"; exit 1;
  }
  [[ -z "$(git -C "$src" status --porcelain)" ]] || {
    echo "::error::Timestamp-only probe dirtied source tree: $mode"; exit 1;
  }
  echo "INCREMENTAL_PROBE_TOUCHED mode=$mode file=AppTheme.swift content_sha256_unchanged=true"
}

report() {
  python3 - "$RUNNER_TEMP" "$GITHUB_STEP_SUMMARY" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
summary_path = pathlib.Path(sys.argv[2])
def load(mode, phase):
    return json.loads((root / f"hermes-exp-{mode}-{phase}.json").read_text(encoding="utf-8"))
wmo_cold = load("wholemodule", "cold")
inc_cold = load("incremental", "cold")
inc_changed = load("incremental", "changed")
wmo_changed = load("wholemodule", "changed")
def seconds(row):
    return float(row["xcodebuild_wall_seconds"])
wmo_rebuild = seconds(wmo_changed)
inc_rebuild = seconds(inc_changed)
saving = wmo_rebuild - inc_rebuild
pct = (saving / wmo_rebuild * 100) if wmo_rebuild else 0.0
same_wmo_ipa = wmo_cold["ipa_sha256"] == wmo_changed["ipa_sha256"]
same_inc_ipa = inc_cold["ipa_sha256"] == inc_changed["ipa_sha256"]
rows = [
    ("WMO", "Cold full Release build", wmo_cold),
    ("Incremental", "Cold full Release build", inc_cold),
    ("WMO", "One-file timestamp-change rebuild", wmo_changed),
    ("Incremental", "One-file timestamp-change rebuild", inc_changed),
]
lines = [
    "## HermesShell build162 — Release WMO vs Incremental experiment",
    "",
    "- Source: 1e57404cae21f567a67d4e2ce92276c101642908",
    "- Toolchain: Xcode 26.3 / iPhoneOS SDK 26.2 / XcodeGen " + (root / "hermes-exp-xcodegen-version.txt").read_text().strip() + " / macOS 15",
    "- All four builds used Release -O; only SWIFT_COMPILATION_MODE changed.",
    "- Probe: touched Sources/HermesShell/AppTheme.swift without changing its contents.",
    "- Each mode used a separate DerivedData directory on the same runner.",
    "",
    "| Mode | Build phase | Xcode build (s) | Swift activity records | Distinct Swift labels | IPA size (MiB) | IPA verification |",
    "|---|---|---:|---:|---:|---:|---|",
]
for mode, phase, row in rows:
    lines.append(
        f"| {mode} | {phase} | {seconds(row):.3f} | "
        f"{row['swift_activity_records']} | {row['distinct_swift_activity_labels']} | "
        f"{row['ipa_bytes']/1048576:.2f} | {row['ipa_verification']} |"
    )
lines += [
    "",
    "### One-file-change rebuild comparison",
    "",
    f"- WMO: **{wmo_rebuild:.3f} s**",
    f"- Incremental: **{inc_rebuild:.3f} s**",
    f"- Incremental saving: **{saving:+.3f} s ({pct:+.1f}%)**",
    f"- WMO IPA unchanged across timestamp-only rebuild: **{same_wmo_ipa}**",
    f"- Incremental IPA unchanged across timestamp-only rebuild: **{same_inc_ipa}**",
    "",
    "### Interpretation",
    "",
]
if inc_rebuild < wmo_rebuild:
    lines.append(
        "Incremental was faster for the controlled one-file-change rebuild. "
        "This supports follow-up validation on a representative real code edit; "
        "it does not authorize changing the production Release setting."
    )
else:
    lines.append(
        "Incremental did not beat WMO for this controlled one-file-change rebuild. "
        "Do not change the production Release setting based on this experiment."
    )
lines += [
    "",
    "### Release safety",
    "",
    "- All four IPA builds passed the existing build162 IPA verifier (arm64, bundle ID, version/build, unsigned package, required resources and gateway symbol).",
    "- No source contents, release metadata, production workflow, 9th-runner workflow, or existing cache workflow were modified.",
    "- No IPA, private compiler log, or DerivedData was uploaded; only aggregate metrics are retained in this run summary.",
]
summary = "\n".join(lines) + "\n"
print(summary)
with summary_path.open("a", encoding="utf-8") as output:
    output.write(summary)
comparison = {
    "source_commit": "1e57404cae21f567a67d4e2ce92276c101642908",
    "toolchain": {"xcode": "26.3", "ios_sdk": "26.2", "xcodegen": (root / "hermes-exp-xcodegen-version.txt").read_text().strip()},
    "optimization": "-O",
    "probe": "touch AppTheme.swift; source contents unchanged",
    "results": {f"{mode}_{phase}": row for mode, phase, row in rows},
    "one_file_rebuild": {
        "wholemodule_seconds": wmo_rebuild,
        "incremental_seconds": inc_rebuild,
        "saving_seconds": saving,
        "saving_percent": pct,
    },
}
(root / "hermes-build162-incremental-comparison.json").write_text(
    json.dumps(comparison, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
PY
}

case "${1:-}" in
  prepare) prepare ;;
  build)
    run_build wholemodule cold
    run_build incremental cold
    touch_probe incremental
    touch_probe wholemodule
    run_build incremental changed
    run_build wholemodule changed
    report
    ;;
  *) echo "Usage: run-incremental-release-experiment.sh prepare|build" >&2; exit 2 ;;
esac
