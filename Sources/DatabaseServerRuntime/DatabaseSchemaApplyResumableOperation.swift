import DatabaseCommandOperations
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseGraphOperations
import DatabaseJobRuntime
import DatabaseKit
import DatabaseMaintenanceOperations
import DatabaseMutationOperations
import DatabaseOperationCore
import DatabaseQueryOperations
import DatabaseSchemaOperations
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import StorageKit

public struct DatabaseSchemaApplyResumableOperation:
    DatabaseResumableOperation
{
    private static let jobKind = "database.schema-apply"

    private let runtimeFactory: AnyDatabaseSchemaRuntimeFactory
    private let runtimeLimits: DatabaseOperationLimits

    #if DATABASE_SERVER_MULTI_BASE
    public var startBaseAdmission: DatabaseBaseAdmissionKind { .administration }
    public var sliceBaseAdmission: DatabaseBaseAdmissionKind { .administration }
    #endif

    public init(
        runtimeFactory: AnyDatabaseSchemaRuntimeFactory,
        runtimeLimits: DatabaseOperationLimits = .default
    ) {
        self.runtimeFactory = runtimeFactory
        self.runtimeLimits = runtimeLimits
    }

    public static func job()
        throws(DatabaseWireError)
        -> JobOperation<
            SchemaExecuteOperation.Request,
            SchemaExecuteOperation.Response
        > {
        try DatabaseOperationCatalog.schemaExecute.resumableJob(kind: jobKind)
    }

    public func compile(
        _ request: SchemaExecuteOperation.Request,
        context: DatabaseResumableOperationStartContext
    ) async throws -> DatabasePreparedResumableJob<
        DatabaseSchemaApplyJobPlan,
        DatabaseSchemaApplyJobState
    > {
        guard
            case .apply(
                let
                    manifest,
                let
                    expectedFingerprint,
                let
                    idempotencyKey
            ) = request.invocation else {
            throw DatabaseSchemaApplyJobError.invalidInvocation
        }
        let executor = try context.operationContext.requireControlExecutor()
        let currentSchema = executor.schema
        let currentFingerprint = executor.schemaFingerprint.detached()
        guard expectedFingerprint == currentFingerprint else {
            throw DatabaseSchemaPublicationError.fingerprintConflict(
                expected: expectedFingerprint,
                actual: currentFingerprint
            )
        }
        let analysis = DatabaseSchemaChangeAnalysis.analyze(
            current: currentSchema,
            target: manifest.schema
        )
        guard analysis.compatibility != .requiresMigration else {
            throw DatabaseSchemaExecutionError.migrationRequired(
                analysis.issues
            )
        }
        let transition = executor.makeSchemaTransitionExecutor(
            runtimeFactory: runtimeFactory
        )
        let preparedRuntime = try await transition.preflight(
            schema: manifest.schema
        )
        let maximumWorkUnits = min(
            context.maximumSliceWorkUnits,
            runtimeLimits.maximumWorkUnits,
            DatabaseIndexMaintenanceRuntime.maximumSliceWorkUnits
        )
        guard maximumWorkUnits > 0 else {
            throw DatabaseSchemaApplyJobError.sliceMadeNoProgress
        }
        #if DATABASE_SERVER_MULTI_BASE
        let baseRecords = try await executor.loadBases(
            transaction: context.transaction
        )
        var dataTargets: [DatabaseSchemaApplyJobPlan.DataTarget] = []
        dataTargets.reserveCapacity(baseRecords.count)
        for record in baseRecords {
            switch record.lifecycle {
            case .active, .retired:
                dataTargets.append(
                    DatabaseSchemaApplyJobPlan.DataTarget(
                        resource: .base(record.id),
                        generation: record.placementGeneration
                    )
                )
            case .tombstone:
                continue
            case .provisioning, .retiring, .moving, .deleting:
                throw DatabaseSchemaApplyJobError
                    .baseLifecycleTransitionInProgress(
                        record.id,
                        record.lifecycle.name
                    )
            }
        }
        #else
        let dataTargets = [
            DatabaseSchemaApplyJobPlan.DataTarget(
                generation: 0
            )
        ]
        #endif
        let indexTransition = try transition.planIndexTransition(
            targetSchema: manifest.schema,
            preparedGeneration: preparedRuntime.generation
        )
        return DatabasePreparedResumableJob(
            plan: try DatabaseSchemaApplyJobPlan(
                previousFingerprint: currentFingerprint,
                targetFingerprint: manifest.fingerprint(),
                indexPhysicalFingerprint:
                    preparedRuntime.generation.indexPhysicalFingerprint,
                manifest: manifest,
                idempotencyKey: idempotencyKey,
                dataTargets: dataTargets,
                indexBuilds: indexTransition.builds,
                indexRetirements: indexTransition.retirements,
                maximumWorkUnitsPerSlice: maximumWorkUnits
            ),
            initialState: DatabaseSchemaApplyJobState(),
            sliceTimeoutMilliseconds:
                runtimeLimits.maximumTimeoutMilliseconds
        )
    }

    public func commitModel(
        for plan: DatabaseSchemaApplyJobPlan
    ) -> DatabaseResumableOperationCommitModel {
        _ = plan
        return .operationCheckpointed
    }

    public func runSlice(
        plan: DatabaseSchemaApplyJobPlan,
        state: DatabaseSchemaApplyJobState,
        maximumWorkUnits: UInt64,
        context: DatabaseResumableOperationContext
    ) async throws -> sending DatabaseResumableOperationSlice<
        DatabaseSchemaApplyJobState,
        SchemaExecuteOperation.Response
    > {
        _ = plan
        _ = state
        _ = maximumWorkUnits
        _ = context
        throw DatabaseJobRuntimeError.commitModelMismatch
    }

    public func runCheckpointedSlice(
        plan: DatabaseSchemaApplyJobPlan,
        state: DatabaseSchemaApplyJobState,
        maximumWorkUnits: UInt64,
        context: DatabaseCheckpointedResumableOperationContext
    ) async throws -> sending DatabaseResumableOperationSlice<
        DatabaseSchemaApplyJobState,
        SchemaExecuteOperation.Response
    > {
        let executor = try context.operationContext.requireControlExecutor()
        let transition = executor.makeSchemaTransitionExecutor(
            runtimeFactory: runtimeFactory
        )
        let manifest = try plan.manifest
        let sliceLimit = min(
            maximumWorkUnits,
            plan.maximumWorkUnitsPerSlice,
            runtimeLimits.maximumWorkUnits,
            DatabaseIndexMaintenanceRuntime.maximumSliceWorkUnits
        )
        guard sliceLimit > 0 else {
            throw DatabaseSchemaApplyJobError.sliceMadeNoProgress
        }

        switch state.phase {
        case .staging:
            guard executor.schemaFingerprint == plan.previousFingerprint else {
                throw DatabaseSchemaApplyJobError.publishedSchemaMismatch
            }
            guard let offset = Int(exactly: state.dataTargetOffset),
                  offset <= plan.dataTargets.count else {
                throw DatabaseJobRuntimeError.corruptedState
            }
            if offset < plan.dataTargets.count {
                let preparedRuntime = try await transition.preflight(
                    schema: manifest.schema,
                    expectedIndexPhysicalFingerprint:
                        plan.indexPhysicalFingerprint
                )
                try await transition.stage(
                    plan.dataTargets[offset],
                    targetSchema: manifest.schema,
                    physicalLayouts:
                        preparedRuntime.generation.indexPhysicalLayouts,
                    retirements: plan.indexRetirements
                )
                return .incomplete(
                    completedWorkUnits: 1,
                    state: DatabaseSchemaApplyJobState(
                        phase: offset + 1 == plan.dataTargets.count
                            ? .publishing
                            : .staging,
                        dataTargetOffset: try increment(state.dataTargetOffset)
                    )
                )
            }
            return .incomplete(
                completedWorkUnits: 1,
                state: DatabaseSchemaApplyJobState(phase: .publishing)
            )

        case .publishing:
            let publication = try await transition.publish(
                manifest: manifest,
                expectedFingerprint: plan.previousFingerprint,
                targetFingerprint: plan.targetFingerprint,
                expectedIndexPhysicalFingerprint:
                    plan.indexPhysicalFingerprint,
                idempotencyKey: plan.idempotencyKey
            )
            guard publication.fingerprint == plan.targetFingerprint,
                publication.indexPhysicalFingerprint
                    == plan.indexPhysicalFingerprint,
                publication.schemaVersion == plan.schemaVersion else {
                throw DatabaseSchemaApplyJobError.publishedSchemaMismatch
            }
            return .incomplete(
                completedWorkUnits: 1,
                state: DatabaseSchemaApplyJobState(phase: .installing)
            )

        case .installing:
            _ = try await transition.preflight(
                schema: manifest.schema,
                expectedIndexPhysicalFingerprint:
                    plan.indexPhysicalFingerprint
            )
            guard executor.schemaFingerprint == plan.targetFingerprint,
                  executor.schema.version == plan.schemaVersion else {
                throw DatabaseSchemaApplyJobError.publishedSchemaMismatch
            }
            guard let offset = Int(exactly: state.dataTargetOffset),
                  offset <= plan.dataTargets.count else {
                throw DatabaseJobRuntimeError.corruptedState
            }
            if offset < plan.dataTargets.count {
                try await transition.installSnapshot(
                    plan.dataTargets[offset],
                    schema: manifest.schema
                )
                return .incomplete(
                    completedWorkUnits: 1,
                    state: DatabaseSchemaApplyJobState(
                        phase: offset + 1 == plan.dataTargets.count
                            ? .building
                            : .installing,
                        dataTargetOffset: offset + 1 == plan.dataTargets.count
                            ? 0
                            : try increment(state.dataTargetOffset)
                    )
                )
            }
            return .incomplete(
                completedWorkUnits: 1,
                state: DatabaseSchemaApplyJobState(phase: .building)
            )

        case .building:
            _ = try await transition.preflight(
                schema: manifest.schema,
                expectedIndexPhysicalFingerprint:
                    plan.indexPhysicalFingerprint
            )
            guard executor.schemaFingerprint == plan.targetFingerprint,
                  executor.schema.version == plan.schemaVersion else {
                throw DatabaseSchemaApplyJobError.publishedSchemaMismatch
            }
            let progress = try await buildSlice(
                plan: plan,
                state: state,
                maximumWorkUnits: sliceLimit,
                transition: transition,
                jobID: context.jobID
            )
            return .incomplete(
                completedWorkUnits: progress.completedWorkUnits,
                state: progress.state
            )

        case .retiring:
            _ = try await transition.preflight(
                schema: manifest.schema,
                expectedIndexPhysicalFingerprint:
                    plan.indexPhysicalFingerprint
            )
            guard executor.schemaFingerprint == plan.targetFingerprint,
                executor.schema.version == plan.schemaVersion
            else {
                throw DatabaseSchemaApplyJobError.publishedSchemaMismatch
            }
            let progress = try await retireSlice(
                plan: plan,
                state: state,
                targetSchema: manifest.schema,
                transition: transition
            )
            return .incomplete(
                completedWorkUnits: progress.completedWorkUnits,
                state: progress.state
            )

        case .finishing:
            _ = try await transition.preflight(
                schema: manifest.schema,
                expectedIndexPhysicalFingerprint:
                    plan.indexPhysicalFingerprint
            )
            let job = try Self.jobIdentity(context.jobID)
            try await transition.finish(job: job)
            return .complete(
                completedWorkUnits: 1,
                result: .applied(
                    SchemaExecuteOperation.Applied(
                        previousFingerprint: plan.previousFingerprint,
                        fingerprint: plan.targetFingerprint,
                        schemaVersion: plan.schemaVersion,
                        generation: executor.schemaGeneration
                    )
                )
            )
        }
    }

    public func prepareUnsuccessfulOutcomeCommit(
        plan: DatabaseSchemaApplyJobPlan,
        state: DatabaseSchemaApplyJobState,
        outcome: DatabaseJobUnsuccessfulOutcome,
        context: DatabaseCheckpointedResumableOperationContext
    ) async throws {
        guard state.phase == .building,
              state.activeBuildStarted,
              let dataTargetOffset = Int(exactly: state.dataTargetOffset),
              plan.dataTargets.indices.contains(dataTargetOffset),
              let indexOffset = Int(exactly: state.indexOffset),
            plan.indexBuilds.indices.contains(indexOffset)
        else {
            return
        }
        let detail: String
        switch outcome {
        case .failed(let error):
            detail = "\(error.code): \(error.message)"
        case .cancelled:
            detail = "cancelled"
        }
        let control = try context.operationContext.requireControlExecutor()
        let transition = control.makeSchemaTransitionExecutor(
            runtimeFactory: runtimeFactory
        )
        let target = plan.indexBuilds[indexOffset]
        let expectedIdentity = target.identity
        try await transition.withDataTarget(
            plan.dataTargets[dataTargetOffset]
        ) { executor in
            try await executor.withDataTransaction(
                requiredAccess: .administer,
                configuration: .batch
            ) { transaction in
                switch target.scope {
                case .entity(let entity, _):
                    guard let partitions = state.activePartitions else {
                        throw DatabaseJobRuntimeError.corruptedState
                    }
                    try await executor.makeIndexMaintenanceRuntime().markFailed(
                        entity: entity,
                        index: target.identity.name,
                        partitions: partitions,
                        generation: context.jobID,
                        detail: detail,
                        expectedIdentity: expectedIdentity,
                        transaction: transaction.executionStorageAccess
                    )
                case .polymorphicGroup(let identifier, _):
                    try await executor
                        .makePolymorphicIndexMaintenanceRuntime()
                        .markFailed(
                            group: identifier,
                            index: target.identity.name,
                            generation: context.jobID,
                    detail: detail,
                            expectedIdentity: expectedIdentity,
                            transaction: transaction.executionStorageAccess
                        )
                }
            }
        }
    }

    public func applyUnsuccessfulOutcome(
        plan: DatabaseSchemaApplyJobPlan,
        state: DatabaseSchemaApplyJobState,
        outcome: DatabaseJobUnsuccessfulOutcome,
        context: DatabaseResumableOperationContext
    ) async throws {
        _ = plan
        _ = state
        _ = outcome
        let executor = try context.operationContext.requireControlExecutor()
        try await executor.finishSchemaApplication(
            job: try Self.jobIdentity(context.jobID),
            transaction: context.transaction
        )
    }

    private static func jobIdentity(
        _ jobID: DatabaseTypes.UUID
    ) throws -> JobIdentity {
        #if DATABASE_SERVER_MULTI_BASE
        JobIdentity(
            jobID: jobID,
            operation: try Self.job().identifier,
            target: .database
        )
        #else
        JobIdentity(
            jobID: jobID,
            operation: try Self.job().identifier
        )
        #endif
    }

    private func buildSlice(
        plan: DatabaseSchemaApplyJobPlan,
        state: DatabaseSchemaApplyJobState,
        maximumWorkUnits: UInt64,
        transition: DatabaseSchemaTransitionExecutor,
        jobID: DatabaseTypes.UUID
    ) async throws -> IndexWorkProgress {
        guard let dataTargetOffset = Int(exactly: state.dataTargetOffset),
              dataTargetOffset <= plan.dataTargets.count,
              let indexOffset = Int(exactly: state.indexOffset),
              indexOffset <= plan.indexBuilds.count else {
            throw DatabaseJobRuntimeError.corruptedState
        }
        guard dataTargetOffset < plan.dataTargets.count else {
            return IndexWorkProgress(
                state: stateAfterBuilds(),
                completedWorkUnits: 1
            )
        }
        guard indexOffset < plan.indexBuilds.count else {
            let nextTarget = try increment(state.dataTargetOffset)
            return IndexWorkProgress(
                state: nextTarget == UInt64(plan.dataTargets.count)
                    ? stateAfterBuilds()
                    : DatabaseSchemaApplyJobState(
                        phase: .building,
                    dataTargetOffset: nextTarget
                ),
                completedWorkUnits: 1
            )
        }

        return try await transition.withDataTarget(
            plan.dataTargets[dataTargetOffset]
        ) { executor in
            try await executor.withDataTransaction(
                requiredAccess: .administer,
                configuration: .batch
            ) { transaction in
                try await buildIndexSlice(
                    plan: plan,
                    state: state,
                    maximumWorkUnits: maximumWorkUnits,
                    executor: executor,
                    jobID: jobID,
                    transaction: transaction.executionStorageAccess
                )
            }
        }
    }

    private func buildIndexSlice(
        plan: DatabaseSchemaApplyJobPlan,
        state: DatabaseSchemaApplyJobState,
        maximumWorkUnits: UInt64,
        executor: DatabaseDataOperationExecutor,
        jobID: DatabaseTypes.UUID,
        transaction: any TransactionAccess
    ) async throws -> IndexWorkProgress {
        guard let offset = Int(exactly: state.indexOffset),
            plan.indexBuilds.indices.contains(offset) else {
            throw DatabaseJobRuntimeError.corruptedState
        }
        let target = plan.indexBuilds[offset]
        let expectedIdentity = target.identity
        if case .polymorphicGroup(let groupIdentifier, _) = target.scope {
            return try await buildPolymorphicIndexSlice(
                plan: plan,
                state: state,
                maximumWorkUnits: maximumWorkUnits,
                executor: executor,
                groupIdentifier: groupIdentifier,
                target: target,
                expectedIdentity: expectedIdentity,
                jobID: jobID,
                transaction: transaction
            )
        }
        guard case .entity(let entityName, _) = target.scope else {
            throw DatabaseJobRuntimeError.corruptedState
        }
        let usesDynamicDirectory = target.scope.usesDynamicDirectory
        var nextContinuation = state.nextPartitionContinuation
        var activePartitions = state.activePartitions
        var activeIsLast = state.activePartitionIsLast
        let activeStarted = state.activeBuildStarted

        if activePartitions == nil {
            if usesDynamicDirectory {
                let page = try await executor.partitionCatalogPage(
                    entity: entityName,
                    continuation: nextContinuation,
                    limit: 1,
                    transaction: transaction
                )
                guard let entry = page.entries.first else {
                    try executor.completeSchemaIndexBuild(
                        target,
                        transaction: transaction
                    )
                    return advancedIndexState(plan: plan, state: state)
                }
                guard target.scope.accepts(partitions: entry.partitions) else {
                    if let continuation = page.continuation {
                        return IndexWorkProgress(
                            state: DatabaseSchemaApplyJobState(
                                phase: .building,
                                dataTargetOffset: state.dataTargetOffset,
                                indexOffset: state.indexOffset,
                                nextPartitionContinuation: continuation
                            ),
                            completedWorkUnits: 1
                        )
                    }
                    try executor.completeSchemaIndexBuild(
                        target,
                        transaction: transaction
                    )
                    return advancedIndexState(plan: plan, state: state)
                }
                activePartitions = entry.partitions
                nextContinuation = page.continuation
                activeIsLast = page.continuation == nil
            } else {
                activePartitions = FieldObject()
                nextContinuation = nil
                activeIsLast = true
            }
        }

        guard let partitions = activePartitions else {
            throw DatabaseJobRuntimeError.corruptedState
        }
        let maintenance = executor.makeIndexMaintenanceRuntime()
        if !activeStarted {
            let status = try await maintenance.status(
                entity: entityName,
                index: target.identity.name,
                partitions: partitions,
                expectedIdentity: expectedIdentity,
                transaction: transaction
            )
            if status.indexState == .readable {
                return try finishedPartitionState(
                    plan: plan,
                    state: state,
                    target: target,
                    isLast: activeIsLast,
                    nextContinuation: nextContinuation,
                    executor: executor,
                    transaction: transaction
                )
            }
        }

        let slice = try await maintenance.runRebuildSlice(
            entity: entityName,
            index: target.identity.name,
            partitions: partitions,
            generation: jobID,
            mode: activeStarted ? .resume : .start,
            maximumWorkUnits: maximumWorkUnits,
            expectedIdentity: expectedIdentity,
            transaction: transaction
        )
        guard slice.completedWorkUnits <= maximumWorkUnits else {
            throw DatabaseJobRuntimeError.sliceExceededBudget(
                actual: slice.completedWorkUnits,
                maximum: maximumWorkUnits
            )
        }
        let chargedWork = max(UInt64(1), slice.completedWorkUnits)
        if !slice.isComplete {
            guard slice.completedWorkUnits > 0 else {
                throw DatabaseSchemaApplyJobError.sliceMadeNoProgress
            }
            return IndexWorkProgress(
                state: DatabaseSchemaApplyJobState(
                    phase: .building,
                    dataTargetOffset: state.dataTargetOffset,
                    indexOffset: state.indexOffset,
                    nextPartitionContinuation: nextContinuation,
                    activePartitions: partitions,
                    activePartitionIsLast: activeIsLast,
                    activeBuildStarted: true
                ),
                completedWorkUnits: chargedWork
            )
        }
        let progress = try finishedPartitionState(
            plan: plan,
            state: state,
            target: target,
            isLast: activeIsLast,
            nextContinuation: nextContinuation,
            executor: executor,
            transaction: transaction
        )
        return IndexWorkProgress(
            state: progress.state,
            completedWorkUnits: chargedWork
        )
    }

    private func finishedPartitionState(
        plan: DatabaseSchemaApplyJobPlan,
        state: DatabaseSchemaApplyJobState,
        target: DatabaseIndexTransitionPlan.Target,
        isLast: Bool,
        nextContinuation: ByteString?,
        executor: DatabaseDataOperationExecutor,
        transaction: any TransactionAccess
    ) throws -> IndexWorkProgress {
        if isLast {
            try executor.completeSchemaIndexBuild(
                target,
                transaction: transaction
            )
            return advancedIndexState(plan: plan, state: state)
        }
        return IndexWorkProgress(
            state: DatabaseSchemaApplyJobState(
                phase: .building,
                dataTargetOffset: state.dataTargetOffset,
                indexOffset: state.indexOffset,
                nextPartitionContinuation: nextContinuation
            ),
            completedWorkUnits: 1
        )
    }

    private func buildPolymorphicIndexSlice(
        plan: DatabaseSchemaApplyJobPlan,
        state: DatabaseSchemaApplyJobState,
        maximumWorkUnits: UInt64,
        executor: DatabaseDataOperationExecutor,
        groupIdentifier: String,
        target: DatabaseIndexTransitionPlan.Target,
        expectedIdentity: DatabaseIndexStorageIdentity,
        jobID: DatabaseTypes.UUID,
        transaction: any TransactionAccess
    ) async throws -> IndexWorkProgress {
        let maintenance = executor.makePolymorphicIndexMaintenanceRuntime()
        if !state.activeBuildStarted {
            let status = try await maintenance.status(
                group: groupIdentifier,
                index: target.identity.name,
                expectedIdentity: expectedIdentity,
                transaction: transaction
            )
            if status.indexState == .readable {
                try executor.completeSchemaIndexBuild(
                    target,
                    transaction: transaction
                )
                return advancedIndexState(plan: plan, state: state)
            }
        }
        let slice = try await maintenance.runRebuildSlice(
            group: groupIdentifier,
            index: target.identity.name,
            generation: jobID,
            mode: state.activeBuildStarted ? .resume : .start,
            maximumWorkUnits: maximumWorkUnits,
            expectedIdentity: expectedIdentity,
            transaction: transaction
        )
        guard slice.completedWorkUnits <= maximumWorkUnits else {
            throw DatabaseJobRuntimeError.sliceExceededBudget(
                actual: slice.completedWorkUnits,
                maximum: maximumWorkUnits
            )
        }
        let chargedWork = max(UInt64(1), slice.completedWorkUnits)
        guard slice.isComplete else {
            guard slice.completedWorkUnits > 0 else {
                throw DatabaseSchemaApplyJobError.sliceMadeNoProgress
            }
            return IndexWorkProgress(
                state: DatabaseSchemaApplyJobState(
                    phase: .building,
                    dataTargetOffset: state.dataTargetOffset,
                    indexOffset: state.indexOffset,
                    activeBuildStarted: true
                ),
                completedWorkUnits: chargedWork
            )
        }
        try executor.completeSchemaIndexBuild(
            target,
            transaction: transaction
        )
        return IndexWorkProgress(
            state: advancedIndexState(plan: plan, state: state).state,
            completedWorkUnits: chargedWork
        )
    }

    private func advancedIndexState(
        plan: DatabaseSchemaApplyJobPlan,
        state: DatabaseSchemaApplyJobState
    ) -> IndexWorkProgress {
        let nextIndex = state.indexOffset + 1
        if nextIndex == UInt64(plan.indexBuilds.count) {
            let nextTarget = state.dataTargetOffset + 1
            return IndexWorkProgress(
                state: nextTarget == UInt64(plan.dataTargets.count)
                    ? stateAfterBuilds()
                    : DatabaseSchemaApplyJobState(
                        phase: .building,
                        dataTargetOffset: nextTarget
                    ),
                completedWorkUnits: 1
            )
        }
        return IndexWorkProgress(
            state: DatabaseSchemaApplyJobState(
                phase: .building,
                dataTargetOffset: state.dataTargetOffset,
                indexOffset: nextIndex
            ),
            completedWorkUnits: 1
        )
    }

    private func stateAfterBuilds() -> DatabaseSchemaApplyJobState {
        return DatabaseSchemaApplyJobState(phase: .retiring)
    }

    private func retireSlice(
        plan: DatabaseSchemaApplyJobPlan,
        state: DatabaseSchemaApplyJobState,
        targetSchema: Schema,
        transition: DatabaseSchemaTransitionExecutor
    ) async throws -> IndexWorkProgress {
        guard let dataTargetOffset = Int(exactly: state.dataTargetOffset),
            dataTargetOffset <= plan.dataTargets.count,
            state.indexOffset == 0
        else {
            throw DatabaseJobRuntimeError.corruptedState
        }
        guard dataTargetOffset < plan.dataTargets.count else {
            return IndexWorkProgress(
                state: DatabaseSchemaApplyJobState(phase: .finishing),
                completedWorkUnits: 1
            )
        }

        let hasPendingRetirement = try await transition.withDataTarget(
            plan.dataTargets[dataTargetOffset]
        ) { executor in
            try await executor.withDataTransaction(
                requiredAccess: .administer,
                configuration: .readOnly
            ) { transaction in
                let pending = try await executor.pendingSchemaIndexRetirements(
                    validFor: targetSchema,
                    transaction: transaction.executionStorageAccess
                )
                return !pending.isEmpty
            }
        }
        guard hasPendingRetirement else {
            return try advancedRetirementTargetState(
                plan: plan,
                state: state
            )
        }

        // Physical generations remain readable until every request admitted
        // under a schema older than the published target has released its
        // lease. The wait is deliberately outside a storage transaction and
        // outside the target's Base/data-root lease.
        try await transition.waitForRetiredSchemaRequestsToDrain(
            expectedFingerprint: plan.targetFingerprint,
            expectedVersion: plan.schemaVersion,
            expectedIndexPhysicalFingerprint: plan.indexPhysicalFingerprint
        )

        return try await transition.withDataTarget(
            plan.dataTargets[dataTargetOffset]
        ) { executor in
            try await executor.withDataTransaction(
                requiredAccess: .administer,
                configuration: .batch
            ) { transaction in
                let pending = try await executor.pendingSchemaIndexRetirements(
                    validFor: targetSchema,
                    transaction: transaction.executionStorageAccess
                )
                guard let target = pending.first else {
                    return try advancedRetirementTargetState(
                        plan: plan,
                        state: state
                    )
                }
                switch target.scope {
                case .entity(let entity, _):
                    if target.scope.usesDynamicDirectory {
                        let page = try await executor.partitionCatalogPage(
                            entity: entity,
                            continuation: state.nextPartitionContinuation,
                            limit: 1,
                            transaction: transaction.executionStorageAccess
                        )
                        guard let entry = page.entries.first else {
                            try executor.completeSchemaIndexRetirement(
                                target,
                                transaction: transaction.executionStorageAccess
                            )
                            return completedRetirementState(state: state)
                        }
                        guard
                            target.scope.accepts(
                                partitions: entry.partitions
                            )
                        else {
                            if let continuation = page.continuation {
                                return IndexWorkProgress(
                                    state: DatabaseSchemaApplyJobState(
                                        phase: .retiring,
                                        dataTargetOffset:
                                            state.dataTargetOffset,
                                        indexOffset: state.indexOffset,
                                        nextPartitionContinuation: continuation
                                    ),
                                    completedWorkUnits: 1
                                )
                            }
                            try executor.completeSchemaIndexRetirement(
                                target,
                                transaction:
                                    transaction.executionStorageAccess
                            )
                            return completedRetirementState(state: state)
                        }
                        try executor.retireSchemaIndexStorage(
                            target,
                            partitions: entry.partitions,
                            transaction: transaction.executionStorageAccess
                        )
                        if let continuation = page.continuation {
                            return IndexWorkProgress(
                                state: DatabaseSchemaApplyJobState(
                                    phase: .retiring,
                                    dataTargetOffset: state.dataTargetOffset,
                                    indexOffset: state.indexOffset,
                                    nextPartitionContinuation: continuation
                                ),
                                completedWorkUnits: 1
                            )
                        }
                    } else {
                        try executor.retireSchemaIndexStorage(
                            target,
                            partitions: FieldObject(),
                            transaction: transaction.executionStorageAccess
                        )
                    }

                case .polymorphicGroup:
                    try executor.retireSchemaIndexStorage(
                        target,
                        partitions: FieldObject(),
                        transaction: transaction.executionStorageAccess
                    )
                }
                try executor.completeSchemaIndexRetirement(
                    target,
                    transaction: transaction.executionStorageAccess
                )
                return completedRetirementState(state: state)
            }
        }
    }

    private func advancedRetirementTargetState(
        plan: DatabaseSchemaApplyJobPlan,
        state: DatabaseSchemaApplyJobState
    ) throws -> IndexWorkProgress {
        let nextTarget = try increment(state.dataTargetOffset)
        return IndexWorkProgress(
            state: nextTarget == UInt64(plan.dataTargets.count)
                ? DatabaseSchemaApplyJobState(phase: .finishing)
                : DatabaseSchemaApplyJobState(
                    phase: .retiring,
                    dataTargetOffset: nextTarget
                ),
                completedWorkUnits: 1
        )
    }

    private func completedRetirementState(
        state: DatabaseSchemaApplyJobState
    ) -> IndexWorkProgress {
        IndexWorkProgress(
            state: DatabaseSchemaApplyJobState(
                phase: .retiring,
                dataTargetOffset: state.dataTargetOffset
            ),
            completedWorkUnits: 1
        )
    }

    private func increment(_ value: UInt64) throws -> UInt64 {
        let result = value.addingReportingOverflow(1)
        guard !result.overflow else {
            throw DatabaseJobRuntimeError.stateRevisionOverflow
        }
        return result.partialValue
    }
}

private struct IndexWorkProgress: Sendable {
    let state: DatabaseSchemaApplyJobState
    let completedWorkUnits: UInt64
}
