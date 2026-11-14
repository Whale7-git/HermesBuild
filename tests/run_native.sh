#!/usr/bin/env bash
# Sync the source and execute the same offline suite used by the build container.
#
# This is the remote entry point for tests/run_container.sh: it ships Sources and
# tests into ios-build and runs the identical script there, so a local run and a
# container run cannot diverge. Do not delete it in favour of calling
# run_container.sh directly -- that only works inside the container.
set -euo pipefail
: "${HERMES_TEST_TARGET:?Set HERMES_TEST_TARGET to your SSH user@host}"
[[ "$HERMES_TEST_TARGET" =~ ^[A-Za-z0-9_.@:-]+$ ]] || { echo "Invalid SSH target" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# A-20: one remote directory per run. The old fixed /work/HermesNativeTests/current
# meant two people, or two branches, tar-extracted over each other's sources and a
# failure message pointed at the other run's files. Timestamp+PID is unique without
# a lock, so a concurrent run neither blocks nor corrupts this one.
REMOTE="/work/HermesNativeTests/$(date +%s)-$$"
# Remove the tree on every exit path, including a failed test run: a leftover tree
# only wastes space on the build host and confuses whoever reads /work next.
cleanup() {
  local status=$?
  ssh -o BatchMode=yes "$HERMES_TEST_TARGET" \
    "docker exec ios-build rm -rf '$REMOTE'" >/dev/null 2>&1 || true
  if (( status != 0 )); then
    echo "Native test run failed (exit $status); remote tree $REMOTE removed." >&2
  fi
}
trap cleanup EXIT
ssh -o BatchMode=yes "$HERMES_TEST_TARGET" "docker exec ios-build mkdir -p '$REMOTE'"
# Ship the whole tree instead of a hand-maintained list.
#
# The list used to be `Sources tests`, and every file the suites grew to need
# had to be added by hand: Vendor/ (three suites failed to compile), then
# release.json, docs/, scripts/, .github/, .gitignore, .gitattributes,
# AGENTS.md (sourcegate failed). Two release cycles hit this, and a local run
# silently could not go green while the container run passed -- the exact
# divergence this script exists to prevent.
#
# An allowlist cannot be kept correct by discipline alone. Exclude only build
# outputs and VCS state; everything else a suite might read is then present by
# construction. tar's --exclude must precede the file arguments or it is
# ignored with a warning and the exclude silently does nothing.
tar --exclude=.git \
    --exclude=.build \
    --exclude=.bsp \
    --exclude=xtool \
    --exclude=releases \
    --exclude=outputs \
    --exclude='*.tgz' \
    -cf - . | ssh -o BatchMode=yes "$HERMES_TEST_TARGET" "docker exec -i ios-build tar xf - -C '$REMOTE'"
ssh -o BatchMode=yes "$HERMES_TEST_TARGET" "docker exec -w '$REMOTE' ios-build bash -lc 'bash tests/run_container.sh'"