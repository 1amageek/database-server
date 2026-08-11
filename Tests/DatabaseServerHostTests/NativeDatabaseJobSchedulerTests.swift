import DatabaseTypes
@testable import DatabaseServerHost
import Testing

@Suite("Native database job scheduler")
struct NativeDatabaseJobSchedulerTests {
    @Test("A wake-up requested by running work never overlaps its handler")
    func scheduledWorkIsSerialized() async throws {
        let scheduler = NativeDatabaseJobScheduler()
        let probe = SchedulerConcurrencyProbe()
        let starts = AsyncStream.makeStream(of: Int.self)
        let releaseFirst = AsyncStream.makeStream(of: Void.self)

        await scheduler.install {
            let invocation = await probe.enter()
            starts.continuation.yield(invocation)
            if invocation == 1 {
                _ = await releaseFirst.stream.first(where: { _ in true })
            }
            await probe.leave()
        }

        var iterator = starts.stream.makeAsyncIterator()
        try await scheduler.ensureWakeUp(
            noLaterThan: Timestamp(secondsSinceUnixEpoch: 0)
        )
        #expect(await iterator.next() == 1)

        try await scheduler.ensureWakeUp(
            noLaterThan: Timestamp(secondsSinceUnixEpoch: 0)
        )
        try await Task.sleep(for: .milliseconds(50))
        #expect(await probe.invocationCount == 1)

        releaseFirst.continuation.yield(())
        #expect(await iterator.next() == 2)
        await scheduler.shutdown()

        #expect(await probe.maximumActiveCount == 1)
        starts.continuation.finish()
        releaseFirst.continuation.finish()
    }
}

private actor SchedulerConcurrencyProbe {
    private(set) var invocationCount = 0
    private(set) var maximumActiveCount = 0
    private var activeCount = 0

    func enter() -> Int {
        invocationCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        return invocationCount
    }

    func leave() {
        activeCount -= 1
    }
}
