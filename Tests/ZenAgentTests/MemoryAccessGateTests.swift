import Foundation
import Testing
@testable import ZenAgent

actor MemoryTestLatch {
    private(set) var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func open() { opened = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite("Memory erasure handoff coordination")
struct MemoryAccessGateTests {
    @Test("database aliases share a gate while independent stores remain independent")
    func scope() {
        let root = FileManager.default.temporaryDirectory
        let first = MemoryAccessGate.forDatabase(root.appendingPathComponent("gate-a.sqlite").path)
        let alias = MemoryAccessGate.forDatabase(root.appendingPathComponent("unused/../gate-a.sqlite").path)
        let second = MemoryAccessGate.forDatabase(root.appendingPathComponent("gate-b.sqlite").path)
        #expect(first === alias)
        #expect(first !== second)
        let transient = MemoryAccessGate.forDatabase(nil)
        #expect(transient !== MemoryAccessGate.forDatabase(nil))
    }

    @Test("erasure waits for an already initiated async provider handoff")
    func exclusion() async {
        let gate = MemoryAccessGate()
        let entered = MemoryTestLatch(), release = MemoryTestLatch(), erased = MemoryTestLatch()
        let reader = Task { await gate.withRead { await entered.open(); await release.wait() } }
        await entered.wait()
        let writer = Task { await gate.withWrite { await erased.open() } }
        for _ in 0..<100 { await Task.yield() }
        #expect(await !erased.opened)
        await release.open()
        await reader.value; await writer.value
        #expect(await erased.opened)
    }

    @Test("a throwing handoff releases its lease for erasure")
    func thrownOperation() async throws {
        let gate = MemoryAccessGate()
        do {
            try await gate.withRead { throw MemoryError.validationUnavailable }
            Issue.record("Expected handoff failure")
        } catch let error as MemoryError { #expect(error == .validationUnavailable) }
        let result = await gate.withWrite { true }
        #expect(result)
    }
}
