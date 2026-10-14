@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseRuntime
import DatabaseServerFoundation
@testable import DatabaseServerRuntime
import DatabaseTypes
import DatabaseWire
import StorageKit
import Synchronization
import TestSupport
import Testing

@Suite("Historical query continuation store", .serialized)
struct DatabaseQueryHistoricalContinuationStoreTests {
    @Test("opaque query state round-trips and replay converges after an identifier collision")
    func queryStateRoundTripsAndReplayConverges() async throws {
        let container = try await makeContainer()
        defer { await container.shutdown() }
        let clock = try FixedClock()
        let identifiers = IdentifierSequence([1, 2, 2, 3, 4, 5])
        let store = makeStore(
            container: container,
            clock: clock,
            identifiers: identifiers
        )
        let authorization = try principal(
            roles: ["reader"],
            tenant: "tenant-a"
        )
        let fingerprint = ByteString(repeating: 0xA1, count: 32)
        let lease = try await executionStorage(for: container)
        let reservation = try await store.beginWrite(
            for: lease,
            schemaGeneration: container.schemaGeneration,
            queryFingerprint: fingerprint,
            authorization: authorization
        )
        let firstToken = try await store.publishHistoricalQuery(
            QueryContinuation([0x10, 0x11]),
            readVersion: 42,
            in: reservation
        )

        #expect(firstToken.count == DatabaseQuerySnapshotStore.continuationByteCount)
        #expect(firstToken.first == DatabaseQuerySnapshotStore.continuationMarker)
        let first = try #require(
            try await store.loadHistoricalQuery(
                continuation: firstToken,
                lease: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: fingerprint,
                authorization: authorization
            )
        )
        #expect(first.readVersion == 42)
        #expect(first.continuation == QueryContinuation([0x10, 0x11]))

        let successor = QueryContinuation([0x20, 0x21])
        let nextToken = try await store.advanceHistoricalQuery(
            first,
            to: successor
        )
        let replayedToken = try await store.advanceHistoricalQuery(
            first,
            to: successor
        )
        #expect(replayedToken == nextToken)
        let next = try #require(
            try await store.loadHistoricalQuery(
                continuation: nextToken,
                lease: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: fingerprint,
                authorization: authorization
            )
        )
        #expect(next.readVersion == 42)
        #expect(next.continuation == successor)

        do {
            try await store.completeHistoricalQuery(first)
            Issue.record("Expected a non-terminal step to remain active")
        } catch let error as DatabaseQueryExecutionError {
            guard case .querySnapshotCorrupted = error else {
                Issue.record("Expected querySnapshotCorrupted, got \(error)")
                return
            }
        }

        do {
            _ = try await store.advanceHistoricalQuery(
                first,
                to: QueryContinuation([0x30])
            )
            Issue.record("Expected replay with different state to fail")
        } catch let error as DatabaseQueryExecutionError {
            guard case .querySnapshotCorrupted = error else {
                Issue.record("Expected querySnapshotCorrupted, got \(error)")
                return
            }
        }
    }

    @Test("opaque graph state round-trips and replay converges after an identifier collision")
    func graphStateRoundTripsAndReplayConverges() async throws {
        let container = try await makeContainer()
        defer { await container.shutdown() }
        let store = makeStore(
            container: container,
            clock: try FixedClock(),
            identifiers: IdentifierSequence([40, 41, 41, 42, 43, 44])
        )
        let authorization = try principal(
            roles: ["reader"],
            tenant: "tenant-a"
        )
        let queryFingerprint = ByteString(repeating: 0xE5, count: 32)
        let resultFingerprint = ByteString(repeating: 0xF6, count: 32)
        let lease = try await executionStorage(for: container)
        let reservation = try await store.beginWrite(
            for: lease,
            schemaGeneration: container.schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization
        )
        let firstToken = try await store.publishHistoricalGraph(
            readVersion: 17,
            resultFingerprint: resultFingerprint,
            offset: 2,
            in: reservation
        )
        let first = try #require(
            try await store.loadHistoricalGraph(
                continuation: firstToken,
                lease: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: queryFingerprint,
                authorization: authorization
            )
        )
        #expect(first.readVersion == 17)
        #expect(first.resultFingerprint == resultFingerprint)
        #expect(first.offset == 2)

        let nextToken = try await store.advanceHistoricalGraph(
            first,
            toOffset: 4
        )
        let replayedToken = try await store.advanceHistoricalGraph(
            first,
            toOffset: 4
        )
        #expect(replayedToken == nextToken)
        let next = try #require(
            try await store.loadHistoricalGraph(
                continuation: nextToken,
                lease: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: queryFingerprint,
                authorization: authorization
            )
        )
        #expect(next.readVersion == 17)
        #expect(next.resultFingerprint == resultFingerprint)
        #expect(next.offset == 4)

        do {
            _ = try await store.advanceHistoricalGraph(first, toOffset: 5)
            Issue.record("Expected replay with a different offset to fail")
        } catch let error as DatabaseQueryExecutionError {
            guard case .querySnapshotCorrupted = error else {
                Issue.record("Expected querySnapshotCorrupted, got \(error)")
                return
            }
        }
    }

    @Test("roles and claims are part of the continuation principal")
    func rolesAndClaimsArePartOfPrincipalFingerprint() async throws {
        let container = try await makeContainer()
        defer { await container.shutdown() }
        let store = makeStore(
            container: container,
            clock: try FixedClock(),
            identifiers: IdentifierSequence([10, 11])
        )
        let fingerprint = ByteString(repeating: 0xB2, count: 32)
        let lease = try await executionStorage(for: container)
        let authorization = try principal(
            roles: ["reader"],
            tenant: "tenant-a"
        )
        let reservation = try await store.beginWrite(
            for: lease,
            schemaGeneration: container.schemaGeneration,
            queryFingerprint: fingerprint,
            authorization: authorization
        )
        let token = try await store.publishHistoricalQuery(
            QueryContinuation([0x40]),
            readVersion: 7,
            in: reservation
        )

        try await expectInvalidContinuation {
            _ = try await store.loadHistoricalQuery(
                continuation: token,
                lease: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: fingerprint,
                authorization: try principal(
                    roles: ["writer"],
                    tenant: "tenant-a"
                )
            )
        }
        try await expectInvalidContinuation {
            _ = try await store.loadHistoricalQuery(
                continuation: token,
                lease: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: fingerprint,
                authorization: try principal(
                    roles: ["reader"],
                    tenant: "tenant-b"
                )
            )
        }
        #expect(
            try await store.loadHistoricalQuery(
                continuation: token,
                lease: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: fingerprint,
                authorization: authorization
            ) != nil
        )
    }

    @Test("historical state rejects growth before exceeding its durable byte limit")
    func historicalStateRejectsGrowthAtDurableLimit() async throws {
        let container = try await makeContainer()
        defer { await container.shutdown() }
        let store = makeStore(
            container: container,
            clock: try FixedClock(),
            identifiers: IdentifierSequence([20, 21, 22]),
            historicalStorageByteLimit: 48
        )
        let fingerprint = ByteString(repeating: 0xC3, count: 32)
        let lease = try await executionStorage(for: container)
        let authorization = try principal(
            roles: ["reader"],
            tenant: "tenant-a"
        )
        let reservation = try await store.beginWrite(
            for: lease,
            schemaGeneration: container.schemaGeneration,
            queryFingerprint: fingerprint,
            authorization: authorization
        )
        let token = try await store.publishHistoricalQuery(
            QueryContinuation(ByteString(repeating: 0x55, count: 8)),
            readVersion: 9,
            in: reservation
        )
        let current = try #require(
            try await store.loadHistoricalQuery(
                continuation: token,
                lease: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: fingerprint,
                authorization: authorization
            )
        )

        do {
            _ = try await store.advanceHistoricalQuery(
                current,
                to: QueryContinuation(
                    ByteString(repeating: 0x66, count: 8)
                )
            )
            Issue.record("Expected the durable byte limit to reject growth")
        } catch let error as DatabaseQueryExecutionError {
            guard case .querySnapshotStorageLimitExceeded(
                maximumBytes: 48
            ) = error else {
                Issue.record(
                    "Expected querySnapshotStorageLimitExceeded, got \(error)"
                )
                return
            }
        }
        #expect(
            try await store.loadHistoricalQuery(
                continuation: token,
                lease: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: fingerprint,
                authorization: authorization
            )?.continuation == current.continuation
        )
    }

    @Test("historical continuation expiry is absolute")
    func historicalContinuationExpiryIsAbsolute() async throws {
        let container = try await makeContainer()
        defer { await container.shutdown() }
        let clock = try FixedClock()
        let store = makeStore(
            container: container,
            clock: clock,
            identifiers: IdentifierSequence([30, 31])
        )
        let fingerprint = ByteString(repeating: 0xD4, count: 32)
        let lease = try await executionStorage(for: container)
        let authorization = try principal(
            roles: ["reader"],
            tenant: "tenant-a"
        )
        let reservation = try await store.beginWrite(
            for: lease,
            schemaGeneration: container.schemaGeneration,
            queryFingerprint: fingerprint,
            authorization: authorization
        )
        let token = try await store.publishHistoricalQuery(
            QueryContinuation([0x70]),
            readVersion: 11,
            in: reservation
        )
        try clock.advance(seconds: 15 * 60 + 1)

        do {
            _ = try await store.loadHistoricalQuery(
                continuation: token,
                lease: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: fingerprint,
                authorization: authorization
            )
            Issue.record("Expected the historical continuation to expire")
        } catch let error as DatabaseQueryExecutionError {
            guard case .querySnapshotExpired = error else {
                Issue.record("Expected querySnapshotExpired, got \(error)")
                return
            }
        }
    }

    @Test("terminal historical query releases its active slot and replays")
    func terminalHistoricalQueryReleasesActiveSlotAndReplays() async throws {
        let container = try await makeContainer()
        defer { await container.shutdown() }
        let clock = try FixedClock()
        let store = makeStore(
            container: container,
            clock: clock,
            identifiers: IdentifierSequence(
                Array(UInt64(1)...UInt64(80))
            )
        )
        let fingerprint = ByteString(repeating: 0xA7, count: 32)
        let lease = try await executionStorage(for: container)
        let authorization = try principal(
            roles: ["reader"],
            tenant: "terminal-query"
        )
        var terminalToken: ByteString?
        var firstTerminalCurrent:
            DatabaseQuerySnapshotStore.HistoricalQueryContinuation?

        for index in 0..<8 {
            let reservation = try await store.beginWrite(
                for: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: fingerprint,
                authorization: authorization
            )
            let token = try await store.publishHistoricalQuery(
                QueryContinuation([UInt8(index + 1)]),
                readVersion: UInt64(index + 1),
                in: reservation
            )
            let current = try #require(
                try await store.loadHistoricalQuery(
                    continuation: token,
                    lease: lease,
                    schemaGeneration: container.schemaGeneration,
                    queryFingerprint: fingerprint,
                    authorization: authorization
                )
            )
            if index == 0 {
                firstTerminalCurrent = current
            }
            try await store.completeHistoricalQuery(current)
            terminalToken = token
        }

        let reusedSlotReservation = try await store.beginWrite(
            for: lease,
            schemaGeneration: container.schemaGeneration,
            queryFingerprint: fingerprint,
            authorization: authorization
        )
        var activeReservations = [reusedSlotReservation]
        for _ in 0..<7 {
            activeReservations.append(
                try await store.beginWrite(
                    for: lease,
                    schemaGeneration: container.schemaGeneration,
                    queryFingerprint: fingerprint,
                    authorization: authorization
                )
            )
        }
        try await store.completeHistoricalQuery(
            try #require(firstTerminalCurrent)
        )
        var rejectedAtLimit = false
        do {
            let unexpected = try await store.beginWrite(
                for: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: fingerprint,
                authorization: authorization
            )
            try await store.abortWrite(unexpected)
            Issue.record(
                "A completed continuation cleared a reused active slot"
            )
        } catch let error as DatabaseQueryExecutionError {
            guard case .querySnapshotLimitExceeded(maximum: 8) = error else {
                Issue.record(
                    "Expected querySnapshotLimitExceeded, got \(error)"
                )
                rejectedAtLimit = false
                for reservation in activeReservations {
                    try await store.abortWrite(reservation)
                }
                return
            }
            rejectedAtLimit = true
        }
        #expect(rejectedAtLimit)
        for reservation in activeReservations {
            try await store.abortWrite(reservation)
        }

        let replayToken = try #require(terminalToken)
        let replay = try #require(
            try await store.loadHistoricalQuery(
                continuation: replayToken,
                lease: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: fingerprint,
                authorization: authorization
            )
        )
        #expect(replay.continuation == QueryContinuation([0x08]))

        let replayedReadVersions = try await withThrowingTaskGroup(
            of: UInt64.self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    guard let replay = try await store.loadHistoricalQuery(
                        continuation: replayToken,
                        lease: lease,
                        schemaGeneration: container.schemaGeneration,
                        queryFingerprint: fingerprint,
                        authorization: authorization
                    ) else {
                        throw DatabaseQueryExecutionError.invalidContinuation
                    }
                    return replay.readVersion
                }
            }
            var values: [UInt64] = []
            for try await readVersion in group {
                values.append(readVersion)
            }
            return values
        }
        #expect(
            replayedReadVersions
                == Array(repeating: UInt64(8), count: 8)
        )
    }

    @Test("terminal historical graph releases its active slot and replays")
    func terminalHistoricalGraphReleasesActiveSlotAndReplays() async throws {
        let container = try await makeContainer()
        defer { await container.shutdown() }
        let store = makeStore(
            container: container,
            clock: try FixedClock(),
            identifiers: IdentifierSequence(
                Array(UInt64(100)...UInt64(110))
            )
        )
        let queryFingerprint = ByteString(repeating: 0xB8, count: 32)
        let resultFingerprint = ByteString(repeating: 0xC9, count: 32)
        let lease = try await executionStorage(for: container)
        let authorization = try principal(
            roles: ["reader"],
            tenant: "terminal-graph"
        )
        let reservation = try await store.beginWrite(
            for: lease,
            schemaGeneration: container.schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization
        )
        let token = try await store.publishHistoricalGraph(
            readVersion: 19,
            resultFingerprint: resultFingerprint,
            offset: 2,
            in: reservation
        )
        let current = try #require(
            try await store.loadHistoricalGraph(
                continuation: token,
                lease: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: queryFingerprint,
                authorization: authorization
            )
        )

        try await store.completeHistoricalGraph(current)
        let ninth = try await store.beginWrite(
            for: lease,
            schemaGeneration: container.schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization
        )
        try await store.abortWrite(ninth)

        let replay = try #require(
            try await store.loadHistoricalGraph(
                continuation: token,
                lease: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: queryFingerprint,
                authorization: authorization
            )
        )
        #expect(replay.offset == 2)
        #expect(replay.resultFingerprint == resultFingerprint)
    }

    @Test("terminal durable page releases its active slot and replays")
    func terminalDurablePageReleasesActiveSlotAndReplays() async throws {
        let container = try await makeContainer()
        defer { await container.shutdown() }
        let clock = try FixedClock()
        let store = makeStore(
            container: container,
            clock: clock,
            identifiers: IdentifierSequence(
                Array(UInt64(200)...UInt64(260))
            )
        )
        let fingerprint = ByteString(repeating: 0xDA, count: 32)
        let authorization = try principal(
            roles: ["reader"],
            tenant: "terminal-page"
        )
        let lease = try await executionStorage(for: container)
        #if DATABASE_SERVER_MULTI_BASE
        let pageConsistency = try DatabaseReadConsistency.transactional(
            DomainReadPoint(
                domainID: "database",
                position: .version(1)
            )
        )
        let page = try QueryRowPage(
            columns: [try QueryColumn(number: 1, name: "value", type: .primitive(.string), isNullable: false)],
            rows: [DatabaseWire.QueryRow(values: [.primitive(.string("terminal"))])],
            provenance: nil,
            consistency: pageConsistency
        )
        #else
        let page = try QueryRowPage(
            columns: [try QueryColumn(number: 1, name: "value", type: .primitive(.string), isNullable: false)],
            rows: [DatabaseWire.QueryRow(values: [.primitive(.string("terminal"))])],
            snapshotVersion: nil
        )
        #endif
        let budget = ExecutionBudget()
        let workMeter = DatabaseWorkMeter(
            budget: budget,
            monotonicClock: TestProcessMonotonicClock()
        )
        var terminalToken: ByteString?

        for _ in 0..<8 {
            let reservation = try await store.beginWrite(
                for: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: fingerprint,
                authorization: authorization
            )
            let pageID = try await store.reservePage(in: reservation)
            let totalPayloadBytes = try await store.appendPage(
                page,
                pageID: pageID,
                to: reservation,
                consumedPayloadBytes: 0,
                maximumIntermediateBytes: budget.maximumIntermediateBytes,
                workMeter: workMeter
            )
            try await store.commitWrite(
                reservation,
                pageCount: 1,
                totalPayloadBytes: totalPayloadBytes
            )
            let token = reservation.continuation(pageID: pageID)
            let loaded = try await store.load(
                continuation: token,
                lease: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: fingerprint,
                authorization: authorization
            )
            #expect(loaded.rowCount == 1)
            terminalToken = token
        }

        let ninth = try await store.beginWrite(
            for: lease,
            schemaGeneration: container.schemaGeneration,
            queryFingerprint: fingerprint,
            authorization: authorization
        )
        try await store.abortWrite(ninth)

        let replay = try await store.load(
            continuation: try #require(terminalToken),
            lease: lease,
            schemaGeneration: container.schemaGeneration,
            queryFingerprint: fingerprint,
            authorization: authorization
        )
        #expect(replay.rowCount == 1)
        #expect(replay.continuation == nil)
    }

    @Test(
        "expired historical continuation cleanup survives caller cancellation",
        .timeLimit(.minutes(1))
    )
    func expiredContinuationCleanupSurvivesCallerCancellation() async throws {
        // The expiry branch releases the reservation it has just found
        // expired. Every commit is dispatched from an unstructured task, so
        // cancelling the caller while its manifest read commits does not
        // cancel that read: the load still reaches the expiry branch, and the
        // only remaining cancellation observation point is the cleanup
        // transaction's own pre-commit check. Cleanup owned by the cancelled
        // caller dies there and leaks the reservation; detached cleanup
        // completes and the manifest is gone.
        let engine = CommitGatedInMemoryEngine()
        let container = try await makeContainer(storageEngine: engine)
        defer { await container.shutdown() }
        let clock = try FixedClock()
        let store = makeStore(
            container: container,
            clock: clock,
            identifiers: IdentifierSequence([50, 51])
        )
        let fingerprint = ByteString(repeating: 0xC7, count: 32)
        let lease = try await executionStorage(for: container)
        let authorization = try principal(
            roles: ["reader"],
            tenant: "tenant-a"
        )
        let reservation = try await store.beginWrite(
            for: lease,
            schemaGeneration: container.schemaGeneration,
            queryFingerprint: fingerprint,
            authorization: authorization
        )
        let token = try await store.publishHistoricalQuery(
            QueryContinuation([0x80]),
            readVersion: 21,
            in: reservation
        )
        try clock.advance(seconds: 15 * 60 + 1)

        let gate = engine.suspendNextReadOnlyCommit()
        let load = Task {
            try await store.loadHistoricalQuery(
                continuation: token,
                lease: lease,
                schemaGeneration: container.schemaGeneration,
                queryFingerprint: fingerprint,
                authorization: authorization
            )
        }
        await gate.waitUntilStarted()
        load.cancel()
        await gate.release()

        do {
            _ = try await load.value
            Issue.record("Expected the historical continuation to expire")
        } catch let error as DatabaseQueryExecutionError {
            guard case .querySnapshotExpired = error else {
                Issue.record("Expected querySnapshotExpired, got \(error)")
                return
            }
        }

        let reloaded = try await store.loadHistoricalQuery(
            continuation: token,
            lease: lease,
            schemaGeneration: container.schemaGeneration,
            queryFingerprint: fingerprint,
            authorization: authorization
        )
        #expect(reloaded == nil)
    }

    /// Resolves the execution lease the store binds its continuation identity
    /// to. `MultiBase` reads the lease from the active data-root context, so it
    /// is taken inside one bounded data operation on the fixed test Base.
    private func executionStorage(
        for container: DBContainer
    ) async throws -> DatabaseExecutionStorage {
        let context = container.testBaseContext()
        return try await context.withDataOperation {
            try context.executionStorage()
        }
    }

    private func makeContainer(
        storageEngine: any StorageEngine = InMemoryEngine()
    ) async throws -> DBContainer {
        try await DBContainer.open(
            for: try Schema(
                entities: [try DatabaseEndpointEntity.schemaEntity],
                version: Schema.Version(1, 0, 0)
            ),
            configuration: .testing(storageEngine: storageEngine),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "historical-continuation-store-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        DatabaseEndpointEntity.self
                    )
                ]
            ),
            security: .testingDisabled
        )
    }

    private func makeStore(
        container: DBContainer,
        clock: FixedClock,
        identifiers: IdentifierSequence,
        historicalStorageByteLimit: UInt64 = DatabaseQuerySnapshotStore
            .maximumSpoolBytes
    ) -> DatabaseQuerySnapshotStore {
        DatabaseQuerySnapshotStore(
            container: container,
            clock: AnyDatabaseWallClock(clock),
            identifierGenerator: AnyDatabaseUUIDGenerator(identifiers),
            scheduler: AnyDatabaseJobScheduler(Scheduler()),
            wireLimits: .default,
            historicalStorageByteLimit: historicalStorageByteLimit
        )
    }

    private func principal(
        roles: Set<String>,
        tenant: String
    ) throws -> AuthorizationContext {
        .authenticated(
            Principal(
                identifier: "continuation-user",
                roles: roles,
                claims: try FieldObject([
                    (key: "tenant", value: .string(tenant))
                ])
            )
        )
    }

    private func expectInvalidContinuation(
        _ operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            Issue.record("Expected invalidContinuation")
        } catch let error as DatabaseQueryExecutionError {
            guard case .invalidContinuation = error else {
                Issue.record("Expected invalidContinuation, got \(error)")
                return
            }
        }
    }

    private final class FixedClock: WallClock, Sendable {
        private let timestamp: Mutex<Timestamp>

        init() throws {
            self.timestamp = Mutex(
                try Timestamp(
                    secondsSinceUnixEpoch: 1_000,
                    nanoseconds: 0
                )
            )
        }

        var now: Timestamp { timestamp.withLock { $0 } }

        func advance(seconds: Int64) throws {
            try timestamp.withLock { timestamp in
                timestamp = try Timestamp(
                    secondsSinceUnixEpoch:
                        timestamp.secondsSinceUnixEpoch + seconds,
                    nanoseconds: timestamp.nanoseconds
                )
            }
        }
    }

    private final class IdentifierSequence: DatabaseUUIDGenerator, Sendable {
        private struct State: Sendable {
            let values: [UInt64]
            var index: Int
        }

        private let state: Mutex<State>

        init(_ values: [UInt64]) {
            self.state = Mutex(State(values: values, index: 0))
        }

        func generate() -> DatabaseTypes.UUID {
            state.withLock { state in
                precondition(state.index < state.values.count)
                defer { state.index += 1 }
                return DatabaseTypes.UUID(
                    high: 0,
                    low: state.values[state.index]
                )
            }
        }
    }

    private actor Scheduler: DatabaseJobScheduler {
        func ensureWakeUp(noLaterThan: Timestamp) async throws {
            _ = noLaterThan
        }
    }
}
