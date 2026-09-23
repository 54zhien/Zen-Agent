import Foundation
import Testing

@testable import ZenAgent

@Suite("Streaming coalescer")
struct StreamingCoalescerTests {

    @Test("deltas inside one interval are applied as one concatenated value")
    func coalescesDeltasUntilTheInterval() {
        var coalescer = StreamingCoalescer(interval: .milliseconds(10))
        let start = ContinuousClock.now

        #expect(coalescer.append("a", at: start) == nil)
        #expect(coalescer.append("b", at: start.advanced(by: .milliseconds(5))) == nil)
        #expect(coalescer.append("c", at: start.advanced(by: .milliseconds(10))) == "abc")
    }

    @Test("before the interval stays nil and after it returns the pending text")
    func respectsTheFlushInstant() {
        var coalescer = StreamingCoalescer(interval: .milliseconds(10))
        let start = ContinuousClock.now

        #expect(coalescer.append("a", at: start) == nil)
        #expect(coalescer.append("b", at: start.advanced(by: .milliseconds(9))) == nil)
        #expect(coalescer.append("c", at: start.advanced(by: .milliseconds(11))) == "abc")
    }

    @Test("an empty delta changes nothing")
    func emptyDeltaDoesNoWork() {
        var coalescer = StreamingCoalescer(interval: .milliseconds(10))
        let start = ContinuousClock.now

        #expect(coalescer.append("", at: start) == nil)
        #expect(coalescer.append("text", at: start) == nil)
        #expect(coalescer.flush() == "text")
    }

    @Test("flush publishes pending text even before the interval")
    func semanticFlushIgnoresTheInterval() {
        var coalescer = StreamingCoalescer(interval: .seconds(1))
        let start = ContinuousClock.now

        #expect(coalescer.append("first", at: start) == nil)
        #expect(coalescer.append(" second", at: start.advanced(by: .milliseconds(1))) == nil)
        #expect(coalescer.flush() == "first second")
    }

    @Test("the same deltas and supplied instants produce the same result")
    func suppliedTimeMakesTheSequenceDeterministic() {
        func outputs() -> [String?] {
            var coalescer = StreamingCoalescer(interval: .milliseconds(10))
            let start = ContinuousClock.now
            return [
                coalescer.append("a", at: start),
                coalescer.append("b", at: start.advanced(by: .milliseconds(4))),
                coalescer.append("c", at: start.advanced(by: .milliseconds(10))),
                coalescer.flush(),
            ]
        }

        #expect(outputs() == outputs())
    }
}
