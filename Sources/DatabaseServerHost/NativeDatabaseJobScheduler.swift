import DatabaseOperations
import DatabaseTypes
import Foundation
import ServiceLifecycle

public actor NativeDatabaseJobScheduler: DatabaseJobScheduler, Service {
    public typealias Handler = @Sendable () async throws -> Void

    private let failureStream: AsyncStream<NativeDatabaseJobSchedulerFailure>
    private let failureContinuation:
        AsyncStream<NativeDatabaseJobSchedulerFailure>.Continuation
    private var handler: Handler?
    private var scheduledTimestamp: Timestamp?
    private var scheduledTask: Task<Void, Never>?
    private var isRunningHandler = false
    private var isShutdown = false

    public init() {
        let pair = AsyncStream.makeStream(
            of: NativeDatabaseJobSchedulerFailure.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.failureStream = pair.stream
        self.failureContinuation = pair.continuation
    }

    public func install(handler: @escaping Handler) {
        precondition(self.handler == nil, "Job scheduler handler installed twice")
        precondition(!isShutdown, "Job scheduler handler installed after shutdown")
        self.handler = handler
        scheduleTaskIfPossible()
    }

    public func ensureWakeUp(
        noLaterThan timestamp: Timestamp
    ) async throws {
        guard !isShutdown else {
            throw NativeDatabaseJobSchedulerError.shutDown
        }
        if let scheduledTimestamp, scheduledTimestamp <= timestamp {
            return
        }
        scheduledTimestamp = timestamp
        guard !isRunningHandler else { return }
        scheduledTask?.cancel()
        scheduledTask = nil
        scheduleTaskIfPossible()
    }

    public nonisolated func run() async throws {
        for await failure in failureStream {
            throw failure
        }
    }

    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        let task = scheduledTask
        scheduledTask = nil
        scheduledTimestamp = nil
        task?.cancel()
        if let task {
            await task.value
        }
        failureContinuation.finish()
    }

    private func scheduleTaskIfPossible() {
        guard !isShutdown,
              !isRunningHandler,
              scheduledTask == nil,
              let scheduledTimestamp,
              handler != nil else {
            return
        }
        scheduledTask = Task { [weak self] in
            do {
                try await Self.sleep(until: scheduledTimestamp)
                guard !Task.isCancelled else { return }
                await self?.fire(scheduledTimestamp)
            } catch is CancellationError {
                return
            } catch {
                await self?.report(error)
            }
        }
    }

    private func fire(_ timestamp: Timestamp) async {
        guard !isShutdown,
              scheduledTimestamp == timestamp,
              let handler else {
            return
        }
        scheduledTimestamp = nil
        isRunningHandler = true
        do {
            try await handler()
            isRunningHandler = false
            scheduledTask = nil
            scheduleTaskIfPossible()
        } catch {
            isRunningHandler = false
            scheduledTask = nil
            guard !isShutdown else { return }
            report(error)
        }
    }

    private func report(_ error: any Error) {
        let errorType = String(reflecting: type(of: error))
        failureContinuation.yield(
            NativeDatabaseJobSchedulerFailure.scheduledWorkFailed(
                errorType: errorType
            )
        )
    }

    private nonisolated static func sleep(
        until timestamp: Timestamp
    ) async throws {
        while true {
            let now = Date().timeIntervalSince1970
            let target = Double(timestamp.secondsSinceUnixEpoch)
                + Double(timestamp.nanoseconds) / 1_000_000_000
            let remaining = target - now
            guard remaining > 0 else { return }
            try await Task.sleep(for: .seconds(remaining))
        }
    }
}

public enum NativeDatabaseJobSchedulerError: Error, Sendable, Equatable {
    case shutDown
}

public enum NativeDatabaseJobSchedulerFailure:
    Error,
    Sendable,
    Equatable
{
    case scheduledWorkFailed(errorType: String)
}
