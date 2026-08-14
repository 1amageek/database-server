import DatabaseOperationCore
@_spi(DatabaseExecution) import DatabaseEngine

/// Executes the ordered phases of one persistent-job scheduler delivery.
///
/// Cancellation is checked at every phase boundary and after a
/// noncooperative wake-up scheduler returns.
package func executePersistentJobScheduledWork<DueJob: Sendable>(
    loadDueJobs: () async throws -> [DueJob],
    processJob: (DueJob) async throws -> Void,
    scheduleNextWakeUp: () async throws -> Void,
    isolation actor: isolated (any Actor)? = #isolation
) async throws {
    try ensureDatabaseExecutionTaskIsActive()
    let dueJobs: [DueJob]
    do {
        dueJobs = try await loadDueJobs()
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        try ensureDatabaseExecutionTaskIsActive()
        throw PersistentJobScheduledWorkError.loadingDueJobs(error)
    }
    var firstProcessingError: (any Error)?
    for dueJob in dueJobs {
        try ensureDatabaseExecutionTaskIsActive()
        do {
            try await processJob(dueJob)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ensureDatabaseExecutionTaskIsActive()
            if firstProcessingError == nil {
                firstProcessingError = error
            }
        }
    }
    try ensureDatabaseExecutionTaskIsActive()
    do {
        try await scheduleNextWakeUp()
    } catch {
        if error is CancellationError {
            throw CancellationError()
        }
        try ensureDatabaseExecutionTaskIsActive()
        if let firstProcessingError {
            throw PersistentJobScheduledWorkError
                .processingJobAndSchedulingNextWakeUp(
                    processingError: firstProcessingError,
                    schedulingError: error
                )
        }
        throw PersistentJobScheduledWorkError
            .schedulingNextWakeUp(error)
    }
    try ensureDatabaseExecutionTaskIsActive()
    if let firstProcessingError {
        throw PersistentJobScheduledWorkError
            .processingJob(firstProcessingError)
    }
}
