#!/usr/bin/env bash
# Best-effort Bark notification; never expose the device key.
set -uo pipefail
if [[ -z "${BARK_URL:-}" ]]; then
  echo "::warning::BARK_URL not configured; notification skipped"
  exit 0
fi
status="${1:-failure}"
version="unknown"; build="unknown"
if [[ -f src/release.json ]]; then
  readarray -t fields < <(python3 - <<'PY'
import json
try:
    data=json.load(open("src/release.json",encoding="utf-8"))
    print(data["version"]);print(data["build"])
except (OSError,ValueError,KeyError,TypeError):
    print("unknown");print("unknown")
PY
)
  version="${fields[0]:-unknown}"
  build="${fields[1]:-unknown}"
fi
tag="release-${version}-build${build}"
run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
if [[ "$status" == success ]]; then
  title="HermesShell 正式发布成功"
  body="v${version} build${build} IPA 已发布"
  target="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/releases/tag/${tag}"
else
  title="HermesShell 构建或发布失败"
  body="v${version} build${build}，请查看 Actions 运行日志"
  target="$run_url"
fi
response="$(mktemp)"
trap 'rm -f "$response"' EXIT
code="$(curl --silent --show-error --max-time 20 --retry 1 --request POST \
  --data-urlencode "title=$title" \
  --data-urlencode "body=$body" \
  --data-urlencode "url=$target" \
  --data-urlencode "group=hermes-ci" \
  --output "$response" --write-out '%{http_code}' "$BARK_URL")"
rc=$?
if [[ "$rc" != 0 || "$code" != 200 ]]; then
  echo "::warning::Bark delivery failed (curl=$rc http=${code:-none})"
  exit 0
fi
if python3 - "$response" <<'PY'
import json,sys
try:
    data=json.load(open(sys.argv[1],encoding="utf-8"))
    assert data.get("code")==200
except (OSError,ValueError,AssertionError,AttributeError):
    sys.exit(1)
PY
then
  echo "BARK_SENT status=$status build=$build"
else
  echo "::warning::Bark did not return code=200"
fi
exit 0
