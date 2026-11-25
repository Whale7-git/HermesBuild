#!/usr/bin/env bash
# Run the complete offline suite in CI or a compatible local Swift environment.
# No SSH, credentials, API calls or production writes.
set -euo pipefail
ulimit -c 0
cd "$(dirname "$0")/.."
BUILD=$(mktemp -d /tmp/hermes-unit-XXXXXXXX)
trap 'rm -rf "$BUILD"' EXIT
S=Sources/HermesShell

# Four independent CI jobs; unset SHARD preserves the full local suite.
# Unknown suite names fail loudly, so new regressions cannot silently vanish.
SHARD=${HERMES_TEST_SHARD:-all}
case "$SHARD" in
  all|core|recovery|interface|media) ;;
  *) echo "Unknown HERMES_TEST_SHARD: $SHARD" >&2; exit 2 ;;
esac
COMPILE_LIMIT=${HERMES_TEST_COMPILE_TIMEOUT:-300}
EXEC_LIMIT=${HERMES_TEST_EXEC_TIMEOUT:-180}
EXTRA_LIMIT=${HERMES_TEST_EXTRA_TIMEOUT:-360}
suite_shard() {
  case "$1" in
    backendcapabilities|core|requests|attachmentdispatch|sessionops|modeleffort|gateway|clientaudit|credentials|discovery|quote|slashcommand|transcriptexport|transcriptpager|historycache) echo core ;;
    sessiontask|tasknotifier|taskack|sessionhome|model|drafts|homeflow|appstate|recentmodel|runtimelog|runtimerecorder) echo recovery ;;
    experience|tiledrows|timeline|scroll|scrollgeometry|viewport|conversationreading|findhighlight|findwork|preparation|selectionrelay|blockcoalescer|selectionpublication|input) echo interface ;;
    attachprogress|imagegallery|imagepresentation|build58|iteration53|inlineimage|attachmentinteraction|renderbudget|markdownblocks|renderscheduling|performancestats) echo media ;;
    *) echo "Unassigned offline suite: $1" >&2; return 2 ;;
  esac
}
with_deadline() {
  local seconds=$1; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=10s "${seconds}s" "$@"
  else
    "$@"
  fi
}

# Two-phase runner: compile in parallel, then execute in order.
#
# Why: 44 suites each re-compile overlapping sources with a single `swiftc`
# invocation (ChatCore.swift alone is pulled into ~20 of them). Serially that
# was 154s of the ~5min release, on a 16-core host that sat mostly idle.
#
# Compiling in parallel is safe because every suite writes its own binary and
# reads only its own sources. Executing in parallel would not be: several
# suites bind a loopback fixture server and print interleaved output, and the
# run order is part of how a failure reads. So the binaries are built with
# `wait -n` back-pressure and then run one at a time, in declaration order.
#
# `run` only records the suite; `run_all` does the work at the end of the file.
# That keeps the 44 declarations readable and diff-friendly.
JOBS=${HERMES_TEST_JOBS:-}
if [[ -z $JOBS ]]; then
  JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
  # Cap at 32. Measured on a 16-core / 62 GB CI runner, same tree, only this
  # value varying:
  #   JOBS=8   -> ~150s total, 49s compiling, load 2.7
  #   JOBS=16  -> ~89s  total, 49s compiling, load 4.8
  #   JOBS=32  -> ~83s  total, 40s compiling, load 6.6, 49.5 GB still free
  # Peak concurrency is only 6 swift processes because most of the 49 suites are
  # tiny and finish before the window fills, so raising this further buys
  # nothing: the queue runs dry, not the cores. Compiling is now 40s of an 83s
  # run; the remaining time is the deliberately serial execute phase. Memory is
  # not the constraint here (49.5 GB available at peak), so 32 is safe and
  # leaves the release build afterwards plenty of room.
  JOBS=$(( JOBS > 32 ? 32 : JOBS ))
fi

suite_names=()
declare -A suite_flags=()
declare -A suite_sources=()

run() {
  local name=$1; shift
  local owner
  owner=$(suite_shard "$name") || exit 2
  [[ $SHARD == all || $SHARD == "$owner" ]] || return 0
  suite_names+=("$name")
  # Split leading compiler flags (-swift-version 5, -parse-as-library) from the
  # source list so the compile step can pass them through unchanged.
  local flags=()
  while [[ $# -gt 0 && $1 == -* ]]; do flags+=("$1"); shift; done
  suite_flags[$name]="${flags[*]:-}"
  suite_sources[$name]="$*"
}

compile_one() {
  local name=$1 started
  started=$(date +%s)
  echo "[compile] START $SHARD/$name"
  # shellcheck disable=SC2086
  if ! with_deadline "$COMPILE_LIMIT" swiftc -warnings-as-errors ${suite_flags[$name]} \
       ${suite_sources[$name]} -o "$BUILD/$name" > "$BUILD/$name.compile.log" 2>&1; then
    echo "[compile] FAIL $SHARD/$name after $(($(date +%s) - started))s" >&2
    cat "$BUILD/$name.compile.log" >&2
    return 1
  fi
  echo "[compile] PASS $SHARD/$name in $(($(date +%s) - started))s"
}

run_all() {
  local total=${#suite_names[@]}
  echo "==> shard=$SHARD: compiling $total suites with $JOBS jobs"
  local started compiled=0
  started=$(date +%s)

  # Batch compile: launch up to $JOBS at once, wait for the whole batch, repeat.
  # Simpler and more predictable than `wait -n` bookkeeping, and the batch
  # boundary costs at most one straggler per round.
  local batch=() failed=0
  for name in "${suite_names[@]}"; do
    compile_one "$name" &
    batch+=($!)
    if (( ${#batch[@]} >= JOBS )); then
      for pid in "${batch[@]}"; do
        if ! wait "$pid"; then failed=1; fi
      done
      batch=()
    fi
  done
  for pid in "${batch[@]:-}"; do
    [[ -n $pid ]] || continue
    if ! wait "$pid"; then failed=1; fi
  done

  compiled=$(date +%s)
  if (( failed )); then
    echo "COMPILE_FAILED after $((compiled - started))s" >&2
    exit 1
  fi
  echo "==> compiled $total suites in $((compiled - started))s"

  # Execute in declaration order so failures read the same as before.
  local exec_started; exec_started=$(date +%s)
  for name in "${suite_names[@]}"; do
    local started_one
    started_one=$(date +%s)
    echo "[run] START $SHARD/$name"
    if ! with_deadline "$EXEC_LIMIT" stdbuf -oL "$BUILD/$name"; then
      echo "[run] FAIL $SHARD/$name after $(($(date +%s) - started_one))s" >&2
      return 1
    fi
    echo "[run] PASS $SHARD/$name in $(($(date +%s) - started_one))s"
  done
  echo "==> shard=$SHARD: ran $total suites in $(( $(date +%s) - exec_started ))s"
}
run backendcapabilities "$S/BackendCapabilities.swift" tests/backendcapabilities/main.swift
run core "$S/AttachmentHistory.swift" "$S/ChatCore.swift" tests/core/main.swift
run requests "$S/AttachmentHistory.swift" "$S/ChatRequests.swift" tests/requests/main.swift
run attachmentdispatch -swift-version 5 -parse-as-library "$S/AttachmentHistory.swift" "$S/ChatCore.swift" "$S/ChatRequests.swift" "$S/NativeChatService.swift" tests/attachmentdispatch/main.swift
run sessionops "$S/AttachmentHistory.swift" "$S/ChatCore.swift" "$S/Models.swift" "$S/ChatRequests.swift" tests/sessionops/main.swift
run experience "$S/AttachmentHistory.swift" "$S/ChatCore.swift" "$S/ChatContextPressure.swift" "$S/ExperiencePresentation.swift" tests/experience/main.swift
run sessiontask "$S/Models.swift" "$S/SessionTaskCenter.swift" "$S/TaskAcknowledgement.swift" "$S/SessionHomeSections.swift" "$S/SessionTaskDerivedState.swift" tests/sessiontask/main.swift
run tasknotifier "$S/TaskNotification.swift" "$S/TaskNotificationPlanner.swift" "$S/NotificationNavigation.swift" tests/tasknotifier/main.swift
run taskack "$S/Models.swift" "$S/SessionTaskCenter.swift" "$S/TaskAcknowledgement.swift" tests/taskack/main.swift
run attachprogress -swift-version 5 -parse-as-library "$S/AttachmentHistory.swift" "$S/ChatCore.swift" "$S/AttachmentModels.swift" "$S/AttachmentProgressPresentation.swift" tests/attachprogress/main.swift
run sessionhome "$S/Models.swift" "$S/SessionTaskCenter.swift" "$S/TaskAcknowledgement.swift" "$S/SessionTaskStore.swift" "$S/SessionHomeSections.swift" tests/sessionhome/main.swift
run tiledrows "$S/AttachmentHistory.swift" "$S/ChatCore.swift" "$S/ChatToolSummary.swift" "$S/ChatTimeline.swift" tests/tiledrows/main.swift
run modeleffort "$S/ReasoningEffortPolicy.swift" tests/modeleffort/main.swift
run model -swift-version 5 -parse-as-library "$S/ChatActivity.swift" "$S/ChatPhase.swift" "$S/AttachmentHistory.swift" "$S/ChatCore.swift" "$S/NativeChatService.swift" "$S/LocalDataStorage.swift" "$S/ChatDraftStore.swift" "$S/ChatHistoryStore.swift" "$S/ChatAttachmentPlaceholder.swift" "$S/ImageRatioStore.swift" "$S/RuntimeLogStorage.swift" "$S/RuntimeLogRecorder.swift" "$S/ChatSlashCommand.swift" "$S/ChatSendQueue.swift" "$S/ReasoningEffortPolicy.swift" "$S/HistoryLoadFailure.swift" "$S/NativeChatModel.swift" "$S/NativeChatModel+Send.swift" "$S/NativeChatModel+Stream.swift" "$S/NativeChatModel+Control.swift" tests/model/*.swift
run drafts -swift-version 5 -parse-as-library "$S/LocalDataStorage.swift" "$S/ChatDraftStore.swift" tests/drafts/main.swift
run homeflow "$S/HomeConversationPolicy.swift" tests/homeflow/main.swift
run appstate -swift-version 5 -parse-as-library "$S/AttachmentHistory.swift" "$S/ChatCore.swift" "$S/Models.swift" "$S/SessionTaskCenter.swift" "$S/SessionTaskStore.swift" "$S/ChatHistoryIdentity.swift" "$S/ChatHistoryStore.swift" "$S/ChatAttachmentPlaceholder.swift" "$S/ImageRatioStore.swift" "$S/RuntimeLogStorage.swift" "$S/RuntimeLogRecorder.swift" "$S/RecentModelStore.swift" "$S/LocalDataStorage.swift" "$S/ChatDraftStore.swift" "$S/ChatReadingPosition.swift" "$S/ChatCellStateStore.swift" "$S/SessionRefreshClock.swift" "$S/NativeChatService.swift" "$S/HermesBackend.swift" "$S/BackendCapabilities.swift" "$S/GatewayRunStore.swift" "$S/InstanceCredentialStore.swift" "$S/SessionHomeSections.swift" "$S/SessionTaskDerivedState.swift" "$S/SessionRecoveryCoordinator.swift" "$S/TaskNotification.swift" "$S/TaskNotificationPlanner.swift" "$S/SystemNotificationDeliverer.swift" "$S/NotificationPreference.swift" "$S/TaskAcknowledgement.swift" "$S/CreatedSessionRecoveryStore.swift" "$S/HomeModelActivation.swift" "$S/HomeConversationPolicy.swift" "$S/AppState.swift" tests/appstate/main.swift tests/appstate/TaskCacheTests.swift
run timeline "$S/AttachmentHistory.swift" "$S/ChatCore.swift" "$S/ChatToolSummary.swift" "$S/ChatTimeline.swift" tests/timeline/main.swift
run scroll "$S/ChatScrollState.swift" tests/scroll/main.swift
run scrollgeometry "$S/ChatViewportLayout.swift" "$S/ChatGeometryPlan.swift" tests/scrollgeometry/main.swift
run viewport "$S/ChatViewportLayout.swift" tests/viewport/main.swift
run conversationreading -swift-version 6 "$S/ChatReadingPosition.swift" "$S/ChatConversationSearch.swift" "$S/ChatFindHighlight.swift" "$S/ChatReaderOutline.swift" "$S/ChatViewportLayout.swift" tests/conversationreading/main.swift
run findhighlight "$S/ChatFindHighlight.swift" tests/findhighlight/main.swift
run findwork -swift-version 6 "$S/ChatConversationSearch.swift" "$S/ChatFindHighlight.swift" tests/findwork/main.swift
run transcriptexport "$S/AttachmentHistory.swift" "$S/ChatCore.swift" "$S/TranscriptExporter.swift" tests/transcriptexport/main.swift
run transcriptpager -swift-version 6 -parse-as-library "$S/AttachmentHistory.swift" "$S/ChatCore.swift" "$S/TranscriptPager.swift" tests/transcriptpager/main.swift
run imagegallery -swift-version 6 "$S/ImageGallerySelection.swift" tests/imagegallery/main.swift
run preparation "$S/ChatPreparationQueue.swift" "$S/ChatViewportLayout.swift" tests/preparation/main.swift
run selectionrelay -swift-version 6 -parse-as-library Vendor/Textual/Sources/Textual/Internal/Helpers/TextSelectionUpdateRelay.swift tests/selectionrelay/main.swift
run imagepresentation "$S/ChatAttachmentPlaceholder.swift" "$S/ImageRatioStore.swift" "$S/ChatToolSummary.swift" tests/imagepresentation/main.swift
run recentmodel "$S/RecentModelStore.swift" "$S/Models.swift" "$S/ExternalLinkPolicy.swift" tests/recentmodel/main.swift
run build58 "$S/AttachmentHistory.swift" "$S/ChatCore.swift" "$S/AttachmentModels.swift" "$S/LocalDataStorage.swift" "$S/ChatDraftStore.swift" "$S/ChatReadingPosition.swift" "$S/ChatCellStateStore.swift" tests/build58/main.swift
run iteration53 -swift-version 5 -parse-as-library "$S/AttachmentHistory.swift" "$S/ChatCore.swift" "$S/AttachmentModels.swift" "$S/ImageRatioStore.swift" "$S/ParagraphMergeState.swift" "$S/ImageEditPlan.swift" "$S/AttachmentCatalog.swift" tests/iteration53/main.swift
run gateway -swift-version 6 -parse-as-library "$S/AttachmentHistory.swift" "$S/ChatCore.swift" "$S/Models.swift" "$S/GatewayRequests.swift" "$S/ReasoningEffortPolicy.swift" "$S/GatewayEventMap.swift" "$S/GatewayDecode.swift" "$S/GatewayAttachmentPaths.swift" "$S/GatewayModelCatalog.swift" "$S/GatewaySessionFilter.swift" tests/gateway/main.swift
run blockcoalescer Vendor/Textual/Sources/Textual/Internal/StructuredText/BlockCoalescer.swift tests/blockcoalescer/main.swift
run selectionpublication -swift-version 6 Vendor/Textual/Sources/Textual/Internal/Helpers/TextualSelectionPublication.swift tests/selectionpublication/main.swift
run clientaudit "$S/AttachmentHistory.swift" "$S/Models.swift" "$S/CookieDomainPolicy.swift" tests/clientaudit/main.swift
run runtimelog "$S/RuntimeLogStorage.swift" tests/runtimelog/main.swift
run runtimerecorder -parse-as-library "$S/RuntimeLogStorage.swift" "$S/RuntimeLogRecorder.swift" tests/runtimerecorder/main.swift
run input "$S/ChatInputPolicy.swift" "$S/ChatReadingShortcutPolicy.swift" tests/input/main.swift
run quote "$S/AttachmentHistory.swift" "$S/ChatCore.swift" "$S/ChatComposerInsertion.swift" "$S/ChatQuote.swift" tests/quote/main.swift
run slashcommand "$S/ChatSlashCommand.swift" tests/slashcommand/main.swift
run historycache -swift-version 5 -parse-as-library "$S/AttachmentHistory.swift" "$S/ChatCore.swift" "$S/ChatHistoryStore.swift" tests/historycache/main.swift
run renderbudget "$S/ChatRenderBudget.swift" tests/renderbudget/main.swift
run markdownblocks "$S/MarkdownBlockPlan.swift" tests/markdownblocks/main.swift
run renderscheduling -swift-version 5 -parse-as-library "$S/ChatRenderScheduler.swift" "$S/ChatStreamPacing.swift" tests/renderscheduling/main.swift
run performancestats -swift-version 6 "$S/ChatPerformanceStatistics.swift" tests/performancestats/main.swift
run inlineimage "$S/ChatCore.swift" "$S/AttachmentHistory.swift" "$S/AttachmentModels.swift" "$S/ImageRefKind.swift" tests/inlineimage/main.swift
run attachmentinteraction -swift-version 6 -parse-as-library "$S/AttachmentInteractionState.swift" "$S/SharedAsyncResourcePool.swift" tests/attachmentinteraction/main.swift
run discovery -swift-version 5 -parse-as-library "$S/AttachmentHistory.swift" "$S/Models.swift" "$S/ChatRequests.swift" "$S/SessionSearch.swift" "$S/SessionTaskCenter.swift" "$S/TaskAcknowledgement.swift" "$S/SessionTaskStore.swift" "$S/UnifiedSessionModel.swift" "$S/UnifiedTaskWorkspace.swift" "$S/SessionListService.swift" tests/discovery/Shims.swift tests/discovery/UnifiedSessionTests.swift tests/discovery/UnifiedTaskWorkspaceTests.swift tests/discovery/main.swift
run credentials -swift-version 6 -parse-as-library "$S/AttachmentHistory.swift" "$S/ChatCore.swift" "$S/Models.swift" "$S/InstanceCredentialStore.swift" tests/credentials/main.swift

# Build every recorded suite in parallel, then run them in declaration order.
run_all

# These stay serial and after the suites: each one spawns its own toolchain
# (module builds, a loopback fixture server, a synthetic SwiftUI/UIKit shim
# layer). They already use private mktemp dirs, so they could run together, but
# they are the slowest to diagnose when they interleave — keep the output
# readable instead of chasing the last few seconds.
run_extra() {
  local owner=$1 name=$2; shift 2
  [[ $SHARD == all || $SHARD == "$owner" ]] || return 0
  local started_one
  started_one=$(date +%s)
  echo "[extra] START $SHARD/$name"
  if ! with_deadline "$EXTRA_LIMIT" "$@"; then
    echo "[extra] FAIL $SHARD/$name after $(($(date +%s) - started_one))s" >&2
    return 1
  fi
  echo "[extra] PASS $SHARD/$name in $(($(date +%s) - started_one))s"
}
run_extra interface renderpipeline bash tests/renderpipeline/run.sh
run_extra interface textualprimitives bash tests/textualprimitives/run.sh
run_extra media attachments bash tests/attachments/run_local.sh
run_extra interface selectionactivity bash tests/selectionactivity/run.sh
run_extra core gatewaybackend bash tests/gatewaybackend/run.sh
run_extra core uitest-contract python3 -m unittest discover -s tests/uitest -p 'test_*.py' -v
# MANUAL ONLY (not run here): tests/integration/main.swift is the only real-HTTPS probe.
# It needs a live WebUI base URL, a synthetic session id and a cookie on stdin, and it
# performs GETs against a real gateway, so it cannot run in the offline suite.
# Smoke it by hand against a synthetic conversation:
#   swiftc Sources/HermesShell/{AttachmentHistory,ChatCore,ChatRequests}.swift \
#          tests/integration/main.swift -o /tmp/live-probe
#   echo "<cookie>" | /tmp/live-probe https://<webui-host> <synthetic-session-id>
# Synthetic SSE/history fixtures are exercised by tests/core/main.swift via
# tests/core/fixtures/.
echo "HERMES_OFFLINE_TESTS_PASS shard=$SHARD"
