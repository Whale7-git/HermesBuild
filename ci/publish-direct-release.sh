#!/usr/bin/env bash
# Publish the IPA produced and verified by THIS xtool job, without Actions artifacts.
# The 9th self-hosted runner is the only build/publish execution environment.
set -euo pipefail

: "${GH_TOKEN:?GITHUB_TOKEN must be provided}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be provided}"
: "${GITHUB_SHA:?GITHUB_SHA must be provided}"
[[ "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::Invalid GITHUB_SHA"; exit 2; }

WS="${CI_WORKSPACE:?CI_WORKSPACE must be set}"
RELEASE_DIR="$WS/releases"
[[ -d "$RELEASE_DIR" && -f "$WS/release.json" ]] || { echo "::error::Release workspace missing"; exit 2; }

for command in gh python3 sha256sum; do
  command -v "$command" >/dev/null || { echo "::error::Missing $command"; exit 2; }
done

readarray -t identity < <(python3 - "$WS/release.json" <<'PY'
import json,sys
data=json.load(open(sys.argv[1],encoding="utf-8"))
print(data["version"])
print(data["build"])
PY
)
VERSION="${identity[0]:-}"
BUILD="${identity[1]:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]] || {
  echo "::error::Invalid release version/build"; exit 2;
}
TAG="release-${VERSION}-build${BUILD}"
IPA_NAME="Hermes-${VERSION}-build${BUILD}-unsigned.ipa"
IPA="$RELEASE_DIR/$IPA_NAME"
[[ -s "$IPA" ]] || { echo "::error::IPA missing: $IPA_NAME"; exit 2; }

# Never replace an existing version or move a tag.
if gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$TAG" >/dev/null 2>&1 ||
   gh release view "$TAG" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
  echo "::error::Release tag $TAG already exists. Increase version/build; never overwrite."
  exit 1
fi

# Verify against the exact same commit, with all generated outputs still on the runner.
bash "$WS/ci/publish-verify-artifact.sh" "$RELEASE_DIR" "$GITHUB_SHA"
python3 - "$WS" "$IPA_NAME" "$VERSION" "$BUILD" "$GITHUB_SHA" <<'PY'
import hashlib,json,pathlib,sys
ws=pathlib.Path(sys.argv[1]); name,version,build,sha=sys.argv[2:]
root=ws/"releases"
ipa=root/name
v=json.loads((root/"validation.json").read_text())
info=json.loads((root/"build-info.json").read_text())
assert v["ipa"] == name
assert v["version"] == version and v["build"] == build
assert v["bundle"] == "com.whale7.hermes"
assert v["arch"] == "arm64" and v["unsigned"] is True
assert v["sha256"] == hashlib.sha256(ipa.read_bytes()).hexdigest()
assert info["version"] == version and info["build"] == build
assert info["head_commit"] == sha and info["source_head_commit"] == sha
assert info["working_tree"] == "clean"
print("DIRECT_RELEASE_VERIFIED")
PY

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
cat >"$NOTES" <<EOF
HermesShell ${VERSION} / build${BUILD}

- Unsigned iPhoneOS arm64 IPA for SideStore signing.
- Built and verified by the self-hosted 9th runner using xtool.
- Source commit: ${GITHUB_SHA}
- IPA SHA256: $(sha256sum "$IPA" | cut -d' ' -f1)
- iPhoneOS build, IPA provenance and SHA256 validation passed before publication.
- Full source and offline regressions are deferred to post-release ChatGPT review; their status is not a Release gate.
- Real-device UI acceptance is performed after release.
EOF

gh release create "$TAG" \
  "$IPA" "$RELEASE_DIR/SHA256SUMS.txt" "$RELEASE_DIR/build-info.json" "$RELEASE_DIR/validation.json" \
  --repo "$GITHUB_REPOSITORY" \
  --target "$GITHUB_SHA" \
  --title "Hermes ${VERSION} / build${BUILD}" \
  --notes-file "$NOTES" --latest

# Verify the official Release and its IPA asset are visible after publishing.
gh api "repos/$GITHUB_REPOSITORY/releases/tags/$TAG" | \
  python3 -c 'import json,sys
r=json.load(sys.stdin)
tag,ipa=sys.argv[1:]
ok=(r.get("tag_name")==tag and r.get("draft") is False
    and r.get("prerelease") is False
    and sum(a.get("name")==ipa for a in r.get("assets",[]))==1)
if not ok:
    sys.exit("Release exists but failed post-publish verification")
print("RELEASE_PUBLISHED="+tag)
print("RELEASE_URL="+r.get("html_url",""))' "$TAG" "$IPA_NAME"
