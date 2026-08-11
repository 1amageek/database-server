import DatabaseEngine
import DatabaseWireRuntime
import DatabaseTypes
import StorageKit

public final class DatabaseHostedRuntime: Sendable {
    private actor Lifecycle {
        enum State: Equatable {
            case running
            case shuttingDown
            case shutDown
        }

        private var state = State.running
        private var activeRequestCount = 0
        private var drainWaiters: [CheckedContinuation<Void, Never>] = []
        private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

        func admit() throws(DatabaseHostedRuntimeError) {
            guard state == .running else {
                throw .shuttingDown
            }
            activeRequestCount += 1
        }

        func release() {
            precondition(activeRequestCount > 0)
            activeRequestCount -= 1
            guard activeRequestCount == 0 else { return }
            let waiters = drainWaiters
            drainWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
        }

        func beginShutdown() async -> Bool {
            switch state {
            case .running:
                state = .shuttingDown
                if activeRequestCount > 0 {
                    await withCheckedContinuation { continuation in
                        drainWaiters.append(continuation)
                    }
                }
                return true
            case .shuttingDown:
                await withCheckedContinuation { continuation in
                    shutdownWaiters.append(continuation)
                }
                return false
            case .shutDown:
                return false
            }
        }

        func finishShutdown() {
            precondition(state == .shuttingDown)
            precondition(activeRequestCount == 0)
            state = .shutDown
            let waiters = shutdownWaiters
            shutdownWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private let container: DBContainer
    private let runtime: DatabaseOperationRuntime
    private let lifecycle = Lifecycle()

    public static func open(
        application: AnyDatabaseApplication,
        storageTopology: DatabaseStorageTopology,
        hostServices: DatabaseHostServices
    ) async throws -> DatabaseHostedRuntime {
        let definition: DatabaseContainerDefinition
        do {
            definition = try await application.makeContainerDefinition()
        } catch {
            for domain in storageTopology.domains {
                domain.storageEngine.requestShutdown()
            }
            for domain in storageTopology.domains {
                await domain.storageEngine.waitUntilShutdown()
            }
            throw error
        }
        // DatabaseContainerDefinition transfers the complete topology into
        // DBContainer. Its open path owns authoritative cleanup on failure;
        // the host must not race it with a second engine shutdown.
        let container = try await definition.open(
            storageTopology: storageTopology
        )
        do {
            let configuration = try await application
                .makeRuntimeConfiguration(for: container)
            let runtime = try await DatabaseOperationRuntime(
                container: container,
                configuration: configuration,
                hostServices: hostServices
            )
            return DatabaseHostedRuntime(
                container: container,
                runtime: runtime
            )
        } catch {
            await container.shutdown()
            throw error
        }
    }

    init(container: DBContainer, runtime: DatabaseOperationRuntime) {
        self.container = container
        self.runtime = runtime
    }

    public func execute(
        _ request: ByteString,
        authorization: DatabaseRequestExecutionContext
    ) async throws -> ByteString {
        try await lifecycle.admit()
        do {
            let response = try await runtime.execute(
                request,
                context: authorization
            )
            await lifecycle.release()
            return response
        } catch {
            await lifecycle.release()
            throw error
        }
    }

    public func runScheduledWork() async throws {
        try await lifecycle.admit()
        do {
            try await runtime.runScheduledWork()
            await lifecycle.release()
        } catch {
            await lifecycle.release()
            throw error
        }
    }

    public func shutdown() async {
        guard await lifecycle.beginShutdown() else { return }
        await container.shutdown()
        await lifecycle.finishShutdown()
    }
}

public enum DatabaseHostedRuntimeError: Error, Sendable, Equatable {
    case shuttingDown
}
