import DatabaseTypes
import StorageKit
import Synchronization

/// Preserves real storage behavior while one test owns the commit suspension.
final class SQLExecutionGatedTransaction: Transaction, Sendable {
    private let backing: InMemoryTransaction
    private let gate: SQLExecutionCommitGate
    private let state = Mutex((hasMutations: false, hasCheckpoints: false))

    init(backing: InMemoryTransaction, gate: SQLExecutionCommitGate) {
        self.backing = backing
        self.gate = gate
    }

    var transactionDomain: StorageTransactionDomain { backing.transactionDomain }
    var capabilities: TransactionCapabilities { backing.capabilities }
    var compaction: StorageCompactionAccess? { backing.compaction }
    var storageFailure: StorageError? { backing.storageFailure }
    var mutationByteLimit: Int? { backing.mutationByteLimit }
    var checkpoints: (any TransactionCheckpointAccess)? { backing.checkpoints }
    func configureCheckpoints(limits: TransactionCheckpointLimits) throws {
        try backing.configureCheckpoints(limits: limits)
        state.withLock { $0.hasCheckpoints = true }
    }
    func performOperation(_ operation: @escaping @Sendable () async throws -> Void) async throws { try await backing.performOperation(operation) }
    func configureMutationByteLimit(maximumBytes: Int?) throws { try backing.configureMutationByteLimit(maximumBytes: maximumBytes) }
    func getValue(for key: ByteString) async throws -> ByteString? { try await backing.getValue(for: key) }
    func getValue(for key: ByteString, snapshot: Bool) async throws -> ByteString? { try await backing.getValue(for: key, snapshot: snapshot) }
    func getValue(for key: ByteString, snapshot: Bool, maximumByteCount: Int) async throws -> ByteString? {
        try await backing.getValue(for: key, snapshot: snapshot, maximumByteCount: maximumByteCount)
    }
    func getKey(selector: KeySelector, snapshot: Bool) async throws -> ByteString? { try await backing.getKey(selector: selector, snapshot: snapshot) }
    func rangeCursor(from begin: KeySelector, to end: KeySelector, limit: Int, reverse: Bool,
        snapshot: Bool, streamingMode: StreamingMode) -> KeyValueCursor {
        backing.rangeCursor(from: begin, to: end, limit: limit, reverse: reverse, snapshot: snapshot, streamingMode: streamingMode)
    }
    func setValue(_ value: ByteString, for key: ByteString) throws {
        try backing.setValue(value, for: key)
        state.withLock { $0.hasMutations = true }
    }
    func clear(key: ByteString) throws {
        try backing.clear(key: key)
        state.withLock { $0.hasMutations = true }
    }
    func clearRange(beginKey: ByteString, endKey: ByteString) throws {
        try backing.clearRange(beginKey: beginKey, endKey: endKey)
        state.withLock { $0.hasMutations = true }
    }
    func atomicOp(key: ByteString, param: ByteString, mutationType: MutationType) throws {
        try backing.atomicOp(key: key, param: param, mutationType: mutationType)
        state.withLock { $0.hasMutations = true }
    }
    func setReadVersion(_ version: Int64) throws { try backing.setReadVersion(version) }
    func getReadVersion() async throws -> Int64 { try await backing.getReadVersion() }
    func setOption(forOption option: TransactionOption) throws { try backing.setOption(forOption: option) }
    func setOption(to value: ByteString?, forOption option: TransactionOption) throws { try backing.setOption(to: value, forOption: option) }
    func setOption(to value: Int, forOption option: TransactionOption) throws { try backing.setOption(to: value, forOption: option) }
    func addConflictRange(beginKey: ByteString, endKey: ByteString, type: ConflictRangeType) throws {
        try backing.addConflictRange(beginKey: beginKey, endKey: endKey, type: type)
    }
    func getEstimatedRangeSizeBytes(beginKey: ByteString, endKey: ByteString) async throws -> Int {
        try await backing.getEstimatedRangeSizeBytes(beginKey: beginKey, endKey: endKey)
    }
    func getRangeSplitPoints(beginKey: ByteString, endKey: ByteString, chunkSize: Int) async throws -> [ByteString] {
        try await backing.getRangeSplitPoints(beginKey: beginKey, endKey: endKey, chunkSize: chunkSize)
    }
    func requestVersionstamp() -> any PendingTransactionVersionstamp { backing.requestVersionstamp() }
    func commit() async throws {
        let isProducingSQLMutation = state.withLock { $0.hasMutations && $0.hasCheckpoints }
        if isProducingSQLMutation {
            // The SQL callback prepared its response before the runner dispatched commit.
            await gate.pauseProducingCommitIfArmed()
        }
        try await backing.commit()
    }
    func cancel() async throws { try await backing.cancel() }
    func getCommittedVersion() throws -> Int64 { try backing.getCommittedVersion() }
}
