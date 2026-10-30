# Stage 10 manual measurement

`ZenAgentManualMeasurement` is a separate hosted XCTest scheme. It is not part of
the default `ZenAgent` scheme or CI. The test reads the app's existing
`Application Support/ZenAgent.sqlite` and attaches a content-free JSON snapshot to
the `.xcresult`; it does not create a run or call a Provider.

## Run on an iPhone

1. Install and launch Zen on the iPhone. Configure the intended Provider and its
   credential in the app, then complete a real Parent run with at least one Child.
2. Connect and unlock that iPhone, trust the Mac for development, and select its
   device identifier from `xcrun xctrace list devices`.
3. From the repository root, generate the project and run the manual scheme:

   ```sh
   xcodegen generate
   xcodebuild test -project ZenAgent.xcodeproj \
     -scheme ZenAgentManualMeasurement \
     -destination 'platform=iOS,id=<DEVICE_UDID>' \
     -parallel-testing-enabled NO \
     -only-testing:ZenAgentManualMeasurementTests/Stage10MeasurementReportTests/testAttachLatestParentChildMeasurement \
     -resultBundlePath Stage10Measurement.xcresult
   ```

The attached JSON contains Run and Step IDs, Run state/end reason, reported token
counters, Provider request timestamps, Stop timestamps, and `null` where a value
was not recorded. Run wall duration is `createdAt` through terminal `updatedAt` and
includes preparation, tools, and waiting. Provider timing starts immediately before
`stream(...)` is invoked and ends when Runtime receives the Provider's `finish` event.
The report contains no prompts, model output, credential references, Environment
values, or prices.

Open `Stage10Measurement.xcresult` in Xcode and view the test's
“Stage 10 Parent Child measurement” attachment. A test failure saying no Parent
with a Child exists means the app has no suitable persisted run in that app
container; complete one in Zen and run the scheme again.

The report is an app-data measurement mechanism. It does not establish that any
particular physical-device or live Provider run has been performed; that evidence
must come from the person operating the device and account.
