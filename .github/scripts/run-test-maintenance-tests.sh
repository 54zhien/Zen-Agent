#!/usr/bin/env bash
# Retained behavior around the cleaned test suites; no UI, archive or export.
set -euo pipefail
test "$(git rev-parse HEAD)" = "$SOURCE_SHA"
evidence="$RUNNER_TEMP/test-maintenance-evidence"
mkdir -p "$evidence"
git rev-parse HEAD > "$evidence/source-sha.txt"
xcodebuild -version | tee "$evidence/toolchain.txt"
xcrun simctl list devices available --json > "$evidence/devices.json"
UDID=$(python3 - "$evidence/devices.json" <<'PY'
import json, sys
phones = [d for group in json.load(open(sys.argv[1]))['devices'].values() for d in group
          if d.get('isAvailable') and d['name'].startswith('iPhone')]
assert phones, 'No available iPhone simulator'
print(phones[0]['udid'])
PY
)
xcrun simctl bootstatus "$UDID" -b
common=(-project ZenAgent.xcodeproj -scheme ZenAgent -configuration Debug
        -destination "id=$UDID" -derivedDataPath "$RUNNER_TEMP/TestMaintenanceDerivedData"
        -parallel-testing-enabled NO)
suites=(AgentStepAttemptTests FileAssetPersistenceTests ModelCapabilityTests
        PromptComposerTests ProviderAvailabilityTests ComposerConfigurationTests
        ComposerTextProjectionTests ToolApprovalUITests TypographyTokenTests
        ComposerSendCoordinatorTests ComposerHostIntegrationTests
        DualConversationPaneConcurrencyTests ConversationTimelineProjectionTests
        ReadingPositionStateMachineTests AttachmentSendTests FontAssetPresenceTests)
printf '%s\n' "${suites[@]}" > "$evidence/selected-suites.txt"
selected=()
for suite in "${suites[@]}"; do selected+=("-only-testing:ZenAgentTests/$suite"); done
xcodebuild build-for-testing "${common[@]}" \
  -resultBundlePath "$evidence/Build.xcresult" 2>&1 | tee "$evidence/Build.log"
set +e
xcodebuild test-without-building "${common[@]}" "${selected[@]}" \
  -resultBundlePath "$evidence/Unit.xcresult" 2>&1 | tee "$evidence/Unit.log"
code=${PIPESTATUS[0]}
set -e
xcrun xcresulttool get test-results summary --path "$evidence/Unit.xcresult" > "$evidence/Unit-summary.json"
xcrun xcresulttool get test-results tests --path "$evidence/Unit.xcresult" > "$evidence/Unit-tests.json"
test "$code" -eq 0 || exit "$code"
if grep -Fq 'Restarting after unexpected exit, crash, or test timeout' "$evidence/Unit.log"; then
  echo '::error::Native test host restarted; refusing partial evidence'
  exit 1
fi
python3 - "$evidence" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
summary = json.loads((root / 'Unit-summary.json').read_text())
print(json.dumps(summary, indent=2))
assert summary['totalTestCount'] > 0, 'No tests executed'
assert summary['failedTests'] == 0 and summary['skippedTests'] == 0, 'Failed or skipped tests'
assert summary['passedTests'] == summary['totalTestCount'], 'Incomplete native result'
def nodes(items):
    for item in items:
        yield item
        yield from nodes(item.get('children', []))
tree = json.loads((root / 'Unit-tests.json').read_text())
ran = {node['nodeIdentifierURL'].rsplit('/', 1)[-1]
       for node in nodes(tree['testNodes'])
       if node.get('nodeType') == 'Test Suite' and node.get('result') == 'Passed'
       and node.get('children') and node.get('nodeIdentifierURL')}
selected = set((root / 'selected-suites.txt').read_text().splitlines())
assert selected <= ran, f'Selected suites did not run: {selected - ran}'
PY
