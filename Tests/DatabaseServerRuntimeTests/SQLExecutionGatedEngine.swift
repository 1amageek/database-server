import StorageKit

/// Forwards storage semantics and gates only the real transaction commit boundary.
final class SQLExecutionGatedEngine: StorageEngine, Sendable {
    typealias Configuration = InMemoryEngine.Configuration
    typealias TransactionType = SQLExecutionGatedTransaction

    private let backing: InMemoryEngine
    let gate: SQLExecutionCommitGate

    init(configuration: Configuration) {
        backing = InMemoryEngine(configuration: configuration)
        gate = SQLExecutionCommitGate()
    }

    init(gate: SQLExecutionCommitGate) {
        backing = InMemoryEngine()
        self.gate = gate
    }

    var transactionDomain: StorageTransactionDomain { backing.transactionDomain }
    var directoryAccess: any DirectoryAccess { backing.directoryAccess }
    func createTransaction() throws -> SQLExecutionGatedTransaction {
        SQLExecutionGatedTransaction(backing: try backing.createTransaction(), gate: gate)
    }
    func createOwnedTransaction() throws -> any Transaction { try createTransaction() }
    func requestShutdown() { backing.requestShutdown() }
    func waitUntilShutdown() async { await backing.waitUntilShutdown() }

}
