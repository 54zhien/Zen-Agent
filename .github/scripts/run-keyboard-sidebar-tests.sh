#!/usr/bin/env bash
# Explicit opt-in simulator validation. Never archives, signs or exports an app.
set -euo pipefail
test "$(git rev-parse HEAD)" = "$SOURCE_SHA"
evidence="$RUNNER_TEMP/keyboard-sidebar-evidence"
mkdir -p "$evidence"
git rev-parse HEAD > "$evidence/source-sha.txt"
xcodebuild -version | tee "$evidence/toolchain.txt"
xcrun simctl list devices available --json > "$evidence/devices.json"
UDID=$(python3 - "$evidence/devices.json" <<'PY'
import json, sys
devices = json.load(open(sys.argv[1]))['devices']
phones = [d for group in devices.values() for d in group
          if d.get('isAvailable') and d['name'].startswith('iPhone')]
assert phones, 'No available iPhone simulator'
print(phones[0]['udid'])
PY
)
xcrun simctl bootstatus "$UDID" -b
common=(-project ZenAgent.xcodeproj -scheme ZenAgent -configuration Debug
        -destination "id=$UDID" -derivedDataPath "$RUNNER_TEMP/KeyboardSidebarDerivedData"
        -parallel-testing-enabled NO)
units=(-only-testing:ZenAgentTests/SplitKeyboardLayoutTests
       -only-testing:ZenAgentTests/ConversationNativeScrollViewportTests
       -only-testing:ZenAgentTests/SidebarSurfaceTests
       -only-testing:ZenAgentTests/SidebarDecorationTests
       -only-testing:ZenAgentTests/WorkspaceNavigationStateTests
       -only-testing:ZenAgentTests/ComposerMotionControllerTests)
ui=(-only-testing:ZenAgentUITests/SplitKeyboardUITests
    -only-testing:ZenAgentUITests/SidebarUITests/testStableEditingSidebarDismissesKeyboardWithoutChangingNativeOwner
    -only-testing:ZenAgentUITests/SidebarUITests/testShiftedBlankTapClosesRailWithoutRestoringTheDismissedKeyboard
    -only-testing:ZenAgentUITests/SidebarUITests/testSplitSidebarClosingIncludesOppositePaneAndSharedInput)
printf '%s\n' "${units[@]}" "${ui[@]}" > "$evidence/selected-tests.txt"

xcodebuild build-for-testing "${common[@]}" \
  -resultBundlePath "$evidence/Build.xcresult" 2>&1 | tee "$evidence/Build.log"

run_selected() {
  local phase=$1
  shift
  set +e
  xcodebuild test-without-building "${common[@]}" "$@" \
    -resultBundlePath "$evidence/$phase.xcresult" 2>&1 | tee "$evidence/$phase.log"
  local code=${PIPESTATUS[0]}
  set -e
  xcrun xcresulttool get test-results summary --path "$evidence/$phase.xcresult" \
    > "$evidence/$phase-summary.json" || return 1
  xcrun xcresulttool get test-results tests --path "$evidence/$phase.xcresult" \
    > "$evidence/$phase-tests.json" || return 1
  xcrun xcresulttool export attachments --path "$evidence/$phase.xcresult" \
    --output-path "$evidence/$phase-attachments" || return 1
  test "$code" -eq 0 || return "$code"
  if grep -Fq 'Restarting after unexpected exit, crash, or test timeout' "$evidence/$phase.log"; then
    echo '::error::Native test host restarted; refusing partial evidence'
    return 1
  fi
  python3 - "$evidence/$phase-summary.json" "$phase" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
print(json.dumps(s, indent=2))
assert s['totalTestCount'] > 0, 'No tests executed'
assert s['failedTests'] == 0 and s['skippedTests'] == 0, 'Failed or skipped native tests'
assert s['passedTests'] == s['totalTestCount'], 'Incomplete native test result'
if sys.argv[2] == 'UI':
    assert s['totalTestCount'] == 7, 'Expected four Split scenarios and three focused Sidebar regressions'
else:
    assert s['totalTestCount'] == 27, 'Expected existing 23 tests plus four native viewport regressions'
PY
}

run_selected Unit "${units[@]}"
video_pid=''
stop_video() {
  if [ -n "$video_pid" ]; then
    kill -INT "$video_pid" 2>/dev/null || true
    wait "$video_pid" || true
    video_pid=''
  fi
}
trap stop_video EXIT
xcrun simctl io "$UDID" recordVideo --codec=h264 "$evidence/keyboard-sidebar.mp4" \
  > "$evidence/recording.log" 2>&1 &
video_pid=$!
run_selected UI "${ui[@]}"
stop_video
test -s "$evidence/keyboard-sidebar.mp4"
