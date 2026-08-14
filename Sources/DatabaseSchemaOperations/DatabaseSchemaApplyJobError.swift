import DatabaseJobRuntime
import DatabaseKit
@_spi(DatabaseExecution) import DatabaseWire

public enum DatabaseSchemaApplyJobError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case invalidInvocation
    case corruptedPlan
    #if DATABASE_SERVER_MULTIPLE_BASES
    case baseLifecycleTransitionInProgress(Base.ID, String)
    case baseGenerationChanged(Base.ID)
    #endif
    case publishedSchemaMismatch
    case sliceMadeNoProgress

    public var description: String {
        switch self {
        case .invalidInvocation:
            return "Only schema apply requests can create schema build jobs"
        case .corruptedPlan:
            return "Schema apply job plan is corrupted"
        #if DATABASE_SERVER_MULTIPLE_BASES
        case .baseLifecycleTransitionInProgress(let id, let lifecycle):
            return "Base '\(id.value)' has an in-progress lifecycle transition '\(lifecycle)'"
        case .baseGenerationChanged(let id):
            return "Base '\(id.value)' changed placement during schema application"
        #endif
        case .publishedSchemaMismatch:
            return "Published schema does not match the schema build job"
        case .sliceMadeNoProgress:
            return "Schema index build slice made no progress"
        }
    }
}
