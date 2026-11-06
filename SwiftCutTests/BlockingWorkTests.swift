import Foundation
import Testing
@testable import SwiftCut

struct BlockingWorkTests {
    /// Lots of slow reads at once (like opening a big timeline) must leave Swift's shared
    /// threads free, or everything else async in the app stalls.
    @Test func slowWorkLeavesSharedThreadsFree() async throws {
        let started = Date()
        let slow = Task.detached {
            try await withThrowingTaskGroup(of: Int.self) { group in
                for index in 0..<24 {
                    group.addTask {
                        try await BlockingWork.run { _ in
                            Thread.sleep(forTimeInterval: 0.2)
                            return index
                        }
                    }
                }
                var total = 0
                for try await value in group { total += value }
                return total
            }
        }
        // While those run, plenty of ordinary async work must still get a thread right away.
        try await Task.sleep(for: .milliseconds(50))
        let quickStart = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 { group.addTask { _ = (0..<1000).reduce(0, +) } }
        }
        let quick = Date().timeIntervalSince(quickStart)
        #expect(quick < 0.1, "ordinary async work waited \(quick)s")

        #expect(try await slow.value == (0..<24).reduce(0, +))
        // Limited to a few at a time: 24 jobs of 0.2 s take at least 8 rounds.
        let took = Date().timeIntervalSince(started)
        #expect(took >= 0.2 * Double(24 / BlockingWork.limit) - 0.05, "took \(took)s")
    }

    @Test func cancellingStopsTheWork() async throws {
        let rounds = Counter()
        let task = Task {
            try await BlockingWork.run { isCancelled in
                while !isCancelled() {
                    rounds.add()
                    Thread.sleep(forTimeInterval: 0.01)
                    if rounds.value > 1000 { return "never cancelled" }
                }
                throw CancellationError()
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(rounds.value < 100)
    }

    nonisolated final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }
}
