import DatabaseTypes
import StorageKit
import Synchronization

final class CommitGatedInMemoryEngine: StorageEngine, Sendable {
    struct Configuration: Sendable {
        init() {}
    }

    typealias TransactionType = CommitGatedTransaction

    actor CommitGate {
        private var didStart = false
        private var didRelease = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func waitUntilStarted() async {
            guard !didStart else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        fileprivate func enterAndWait() async {
            didStart = true
            let waiters = startWaiters
            startWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
            guard !didRelease else { return }
            await withCheckedContinuation { continuation in
                if didRelease {
                    continuation.resume()
                } else {
                    releaseWaiter = continuation
                }
            }
        }

        func release() {
            didRelease = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    /// The kind of commit a gate waits for.
    ///
    /// A gate matches one kind so an unrelated commit on the same engine
    /// cannot consume it.
    enum CommitKind: Sendable {
        case mutating
        case readOnly

        fileprivate func matches(containsMutation: Bool) -> Bool {
            switch self {
            case .mutating: containsMutation
            case .readOnly: !containsMutation
            }
        }
    }

    fileprivate final class CommitGateState: Sendable {
        private struct ArmedGate: Sendable {
            let gate: CommitGate
            let kind: CommitKind
            var remainingSkips: Int
        }

        private struct State: Sendable {
            var armed: ArmedGate?
            var mutatingCommits = 0
        }

        private let state = Mutex(State())

        var mutatingCommitCount: Int {
            state.withLock { $0.mutatingCommits }
        }

        func arm(_ kind: CommitKind, skipping: Int) -> CommitGate {
            let newGate = CommitGate()
            state.withLock {
                $0.armed = ArmedGate(
                    gate: newGate,
                    kind: kind,
                    remainingSkips: skipping
                )
            }
            return newGate
        }

        func take(containsMutation: Bool) -> CommitGate? {
            state.withLock { state in
                if containsMutation {
                    state.mutatingCommits += 1
                }
                guard var current = state.armed,
                      current.kind.matches(containsMutation: containsMutation)
                else {
                    return nil
                }
                guard current.remainingSkips == 0 else {
                    current.remainingSkips -= 1
                    state.armed = current
                    return nil
                }
                state.armed = nil
                return current.gate
            }
        }
    }

    final class CommitGatedTransaction: Transaction, Sendable {
        typealias RangeResult = KeyValueRangeResult

        private let underlying: InMemoryTransaction
        private let commitGateState: CommitGateState
        private let containsMutation = Mutex(false)

        var capabilities: TransactionCapabilities { underlying.capabilities }
        var mutationByteLimit: Int? { underlying.mutationByteLimit }
        var transactionDomain: StorageTransactionDomain {
            underlying.transactionDomain
        }
        var storageFailure: StorageError? { underlying.storageFailure }

        fileprivate init(
            underlying: InMemoryTransaction,
            commitGateState: CommitGateState
        ) {
            self.underlying = underlying
            self.commitGateState = commitGateState
        }

        func configureMutationByteLimit(maximumBytes: Int?) throws {
            try underlying.configureMutationByteLimit(maximumBytes: maximumBytes)
        }

        func getValue(for key: ByteString, snapshot: Bool) async throws -> ByteString? {
            try await underlying.getValue(for: key, snapshot: snapshot)
        }

        func getValue(for key: ByteString) async throws -> ByteString? {
            try await underlying.getValue(for: key)
        }

        func getKey(
            selector: KeySelector,
            snapshot: Bool
        ) async throws -> ByteString? {
            try await underlying.getKey(selector: selector, snapshot: snapshot)
        }

        func rangeCursor(
            from begin: KeySelector,
            to end: KeySelector,
            limit: Int,
            reverse: Bool,
            snapshot: Bool,
            streamingMode: StreamingMode
        ) -> KeyValueCursor {
            underlying.rangeCursor(
                from: begin,
                to: end,
                limit: limit,
                reverse: reverse,
                snapshot: snapshot,
                streamingMode: streamingMode
            )
        }

        func setValue(_ value: ByteString, for key: ByteString) throws {
            try underlying.setValue(value, for: key)
            containsMutation.withLock { $0 = true }
        }

        func clear(key: ByteString) throws {
            try underlying.clear(key: key)
            containsMutation.withLock { $0 = true }
        }

        func clearRange(beginKey: ByteString, endKey: ByteString) throws {
            try underlying.clearRange(beginKey: beginKey, endKey: endKey)
            containsMutation.withLock { $0 = true }
        }

        func atomicOp(
            key: ByteString,
            param: ByteString,
            mutationType: MutationType
        ) throws {
            try underlying.atomicOp(
                key: key,
                param: param,
                mutationType: mutationType
            )
            containsMutation.withLock { $0 = true }
        }

        func commit() async throws {
            if let gate = commitGateState.take(
                containsMutation: containsMutation.withLock({ $0 })
            ) {
                // A dispatched commit has an authoritative backend outcome.
                // The gate models commit work that cannot be aborted.
                await gate.enterAndWait()
            }
            try await underlying.commit()
        }

        func cancel() async throws {
            try await underlying.cancel()
        }

        func setReadVersion(_ version: Int64) throws {
            try underlying.setReadVersion(version)
        }

        func getReadVersion() async throws -> Int64 {
            try await underlying.getReadVersion()
        }

        func getCommittedVersion() throws -> Int64 {
            try underlying.getCommittedVersion()
        }

        func setOption(forOption option: TransactionOption) throws {
            try underlying.setOption(forOption: option)
        }

        func setOption(
            to value: ByteString?,
            forOption option: TransactionOption
        ) throws {
            try underlying.setOption(to: value, forOption: option)
        }

        func setOption(
            to value: Int,
            forOption option: TransactionOption
        ) throws {
            try underlying.setOption(to: value, forOption: option)
        }

        func addConflictRange(
            beginKey: ByteString,
            endKey: ByteString,
            type: ConflictRangeType
        ) throws {
            try underlying.addConflictRange(
                beginKey: beginKey,
                endKey: endKey,
                type: type
            )
        }

        func getEstimatedRangeSizeBytes(
            beginKey: ByteString,
            endKey: ByteString
        ) async throws -> Int {
            try await underlying.getEstimatedRangeSizeBytes(
                beginKey: beginKey,
                endKey: endKey
            )
        }

        func getRangeSplitPoints(
            beginKey: ByteString,
            endKey: ByteString,
            chunkSize: Int
        ) async throws -> [ByteString] {
            try await underlying.getRangeSplitPoints(
                beginKey: beginKey,
                endKey: endKey,
                chunkSize: chunkSize
            )
        }

        func requestVersionstamp() -> any PendingTransactionVersionstamp {
            underlying.requestVersionstamp()
        }
    }

    private let underlying = InMemoryEngine()
    private let commitGateState = CommitGateState()

    init() {}

    init(configuration: Configuration) async throws {
        _ = configuration
    }

    /// The number of mutating commits this engine has reached.
    ///
    /// A commit is counted when it arrives, whether or not a gate takes it, so
    /// a caller can measure one request's mutating commits and then gate a
    /// specific one of them on an identically seeded engine.
    var mutatingCommitCount: Int {
        commitGateState.mutatingCommitCount
    }

    func suspendNextMutatingCommit() -> CommitGate {
        commitGateState.arm(.mutating, skipping: 0)
    }

    /// Suspends a mutating commit after letting `skipping` of them through.
    ///
    /// Gating a commit by its position is how a caller reaches work that only
    /// a later commit performs, such as the publication that follows a
    /// query snapshot's spooled pages.
    func suspendMutatingCommit(skipping: Int) -> CommitGate {
        commitGateState.arm(.mutating, skipping: skipping)
    }

    /// Suspends the next read-only commit.
    ///
    /// A read-only transaction commits without mutating storage, so this is
    /// the seam that holds a caller between a completed read and the work the
    /// read result decides to perform. A mutating commit never consumes it.
    func suspendNextReadOnlyCommit() -> CommitGate {
        commitGateState.arm(.readOnly, skipping: 0)
    }

    func createTransaction() throws -> CommitGatedTransaction {
        CommitGatedTransaction(
            underlying: try underlying.createTransaction(),
            commitGateState: commitGateState
        )
    }

    var transactionDomain: StorageTransactionDomain {
        underlying.transactionDomain
    }

    var directoryAccess: any DirectoryAccess {
        underlying.directoryAccess
    }

    func requestShutdown() {
        underlying.requestShutdown()
    }

    func waitUntilShutdown() async {
        await underlying.waitUntilShutdown()
    }
}
