import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
@_spi(DatabaseExecution) import DatabaseWire

public protocol DatabaseResumableOperation: Sendable {
    associatedtype Request: Sendable
    associatedtype Response: Sendable
    associatedtype Plan: PersistentJobPayload
    associatedtype State: PersistentJobPayload

    static func job()
        throws(DatabaseWireError) -> JobOperation<Request, Response>

    #if DATABASE_SERVER_MULTI_BASE
    /// Declares which Base lifecycle admission is required while the job is
    /// validated and compiled. This may be broader than slice admission when
    /// compilation must inspect administrative state while data admission is
    /// closed, as with an offline migration.
    var startBaseAdmission: DatabaseBaseAdmissionKind { get }

    /// Declares which Base lifecycle admission is required while each durable
    /// slice runs. Data maintenance uses active admission by default;
    /// lifecycle operations override this explicitly.
    var sliceBaseAdmission: DatabaseBaseAdmissionKind { get }
    #endif

    func compile(
        _ request: Request,
        context: DatabaseResumableOperationStartContext
    ) async throws -> DatabasePreparedResumableJob<Plan, State>

    func commitModel(
        for plan: Plan
    ) -> DatabaseResumableOperationCommitModel

    func runSlice(
        plan: Plan,
        state: State,
        maximumWorkUnits: UInt64,
        context: DatabaseResumableOperationContext
    ) async throws -> sending DatabaseResumableOperationSlice<State, Response>

    func runCheckpointedSlice(
        plan: Plan,
        state: State,
        maximumWorkUnits: UInt64,
        context: DatabaseCheckpointedResumableOperationContext
    ) async throws -> sending DatabaseResumableOperationSlice<State, Response>

    /// Applies operation-owned state in the same control-domain transaction
    /// that publishes a successful job result. A checkpointed operation must
    /// retain durable ownership evidence until this hook commits.
    func applySuccessfulOutcome(
        plan: Plan,
        state: State,
        context: DatabaseResumableOperationContext
    ) async throws

    /// Completes idempotent operation-owned recovery before the job outcome
    /// is published. This hook runs without a control-domain transaction and
    /// may be repeated after a crash or lease expiry. Implementations must
    /// persist enough ownership evidence for `applyUnsuccessfulOutcome` to
    /// validate the recovery in the final control-domain transaction.
    func prepareUnsuccessfulOutcomeCommit(
        plan: Plan,
        state: State,
        outcome: DatabaseJobUnsuccessfulOutcome,
        context: DatabaseCheckpointedResumableOperationContext
    ) async throws

    /// Applies operation-owned state in the same transaction that publishes
    /// the job's unsuccessful outcome. The transaction may retry this invocation.
    func applyUnsuccessfulOutcome(
        plan: Plan,
        state: State,
        outcome: DatabaseJobUnsuccessfulOutcome,
        context: DatabaseResumableOperationContext
    ) async throws
}

public extension DatabaseResumableOperation {
    #if DATABASE_SERVER_MULTI_BASE
    var startBaseAdmission: DatabaseBaseAdmissionKind { .activeData }
    var sliceBaseAdmission: DatabaseBaseAdmissionKind { .activeData }
    #endif

    func commitModel(
        for plan: Plan
    ) -> DatabaseResumableOperationCommitModel {
        _ = plan
        return .atomicWithJobState
    }

    func runCheckpointedSlice(
        plan: Plan,
        state: State,
        maximumWorkUnits: UInt64,
        context: DatabaseCheckpointedResumableOperationContext
    ) async throws -> sending DatabaseResumableOperationSlice<State, Response> {
        _ = plan
        _ = state
        _ = maximumWorkUnits
        _ = context
        throw DatabaseJobRuntimeError.commitModelMismatch
    }

    func prepareUnsuccessfulOutcomeCommit(
        plan: Plan,
        state: State,
        outcome: DatabaseJobUnsuccessfulOutcome,
        context: DatabaseCheckpointedResumableOperationContext
    ) async throws {
        _ = plan
        _ = state
        _ = outcome
        _ = context
    }

    func applySuccessfulOutcome(
        plan: Plan,
        state: State,
        context: DatabaseResumableOperationContext
    ) async throws {
        _ = plan
        _ = state
        _ = context
    }
}
