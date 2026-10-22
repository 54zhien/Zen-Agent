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
       -only-testing:ZenAgentTests/ConversationPaneScrollBridgeTests
       -only-testing:ZenAgentTests/ConversationNativeScrollViewportTests
       -only-testing:ZenAgentTests/SidebarSurfaceTests
       -only-testing:ZenAgentTests/SidebarDecorationTests
       -only-testing:ZenAgentTests/WorkspaceNavigationStateTests
       -only-testing:ZenAgentTests/ComposerMotionControllerTests
       -only-testing:ZenAgentTests/AppSpaceGeometryTests
       -only-testing:ZenAgentTests/SurfaceLiftGeometryTests
       -only-testing:ZenAgentTests/SurfaceLiftHostTests
       -only-testing:ZenAgentTests/SidebarRailLayoutTests
       -only-testing:ZenAgentTests/SplitTargetingTests
       -only-testing:ZenAgentTests/SplitWorkspaceStateTests
       -only-testing:ZenAgentTests/DeviceFeedbackGeometryTests
       -only-testing:ZenAgentTests/WorkspaceDevicePresentationTests
       -only-testing:ZenAgentTests/WorkspaceComposerDockTests
       -only-testing:ZenAgentTests/ComposerOverlayFocusTests
       -only-testing:ZenAgentTests/ComposerHostIntegrationTests
       -only-testing:ZenAgentTests/SettingsScopeTests)
# Reboot between cases so keyboard-service/animation-idle state cannot cross
# application launches. All real input and presentation assertions stay enabled.
ui=(-only-testing:ZenAgentUITests/SidebarAppearanceUITests/testLightSplitPickerRestoresThePageBackground
    -only-testing:ZenAgentUITests/SplitKeyboardUITests/testConversationAndPickerFillTheKeyboardViewportAndKeepTheirState
    -only-testing:ZenAgentUITests/SplitKeyboardUITests/testPickerAboveConversationRestoresItsViewportAfterKeyboardHides
    -only-testing:ZenAgentUITests/SplitKeyboardUITests/testTwoConversationsKeepTheirDraftsReadingAndRatioAcrossKeyboardCycles
    -only-testing:ZenAgentUITests/SplitKeyboardUITests/testTwoConversationsWithSourceBelowKeepTheirStateAcrossKeyboardCycles)
test "${#ui[@]}" -eq 5
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
  if grep -Fq 'App animations complete notification not received' "$evidence/$phase.log"; then
    echo '::error::Native animation-idle wait timed out; refusing to hide it behind a passing test result'
    return 1
  fi
  python3 - "$evidence/$phase-summary.json" "$phase" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
print(json.dumps(s, indent=2))
assert s['totalTestCount'] > 0, 'No tests executed'
assert s['failedTests'] == 0 and s['skippedTests'] == 0, 'Failed or skipped native tests'
assert s['passedTests'] == s['totalTestCount'], 'Incomplete native test result'
if sys.argv[2].startswith('UI-'):
    assert s['totalTestCount'] == 1, 'Each isolated process must execute exactly its selected UI case'
else:
    assert s['totalTestCount'] == 148, 'Expected the selected native geometry, editor, outline and keyboard regressions'
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
for index in "${!ui[@]}"; do
  phase="UI-$((index + 1))"
  xcrun simctl shutdown "$UDID"
  xcrun simctl bootstatus "$UDID" -b
  xcrun simctl io "$UDID" recordVideo --codec=h264 "$evidence/keyboard-sidebar-$phase.mp4" \
    > "$evidence/recording-$phase.log" 2>&1 &
  video_pid=$!
  run_selected "$phase" "${ui[$index]}"
  stop_video
  test -s "$evidence/keyboard-sidebar-$phase.mp4"
done

python3 - "$evidence" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
paths = sorted(root.glob('UI-*-summary.json'))
assert len(paths) == 5, 'All five isolated cases must finish'
cases = [json.loads(path.read_text()) for path in paths]
assert all(s['totalTestCount'] == 1 and s['passedTests'] == 1
           and s['failedTests'] == s['skippedTests'] == 0 for s in cases)
assert sum(s['totalTestCount'] for s in cases) == 5
report = {'result': 'Passed', 'totalTestCount': 5, 'passedTests': 5,
          'failedTests': 0, 'skippedTests': 0,
          'nativeSummaryFiles': [p.name for p in paths]}
(root / 'UI-aggregate.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
PY
