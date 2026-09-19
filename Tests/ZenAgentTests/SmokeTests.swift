import Testing

@testable import ZenAgent

/// Proves the app unit-test target builds, links against the app module, and
/// actually executes under `xcodebuild test`.
///
/// This is intentionally not a test of anything. Stage 0's gate is "CI can
/// regenerate the project from source, build the app, and run tests" — this is
/// the smallest thing that can be false if any part of that chain is broken.
/// Real coverage starts in Stage 1.
@Suite("Stage 0 smoke")
struct SmokeTests {

    @Test("App module is importable and links")
    func appModuleLinks() {
        // Referencing a type from the app module is what makes this a link test
        // rather than a test of the test bundle itself.
        _ = StageZeroPlaceholderView.self
    }

    @Test("Test process runs")
    func testProcessRuns() {
        #expect(Bool(true))
    }
}
