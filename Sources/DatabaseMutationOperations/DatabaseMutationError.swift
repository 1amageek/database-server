import DatabaseQueryOperations
import DatabaseOperationCore
import DatabaseTypes

public enum DatabaseMutationError: Error, Sendable, CustomStringConvertible {
    case preconditionLimitExceeded(actual: Int, maximum: Int)
    case idempotencyEntryCorrupted
    case invalidGraphPartitions(String)
    case featureUnavailable(String)

    public var description: String {
        switch self {
        case .preconditionLimitExceeded(let actual, let maximum):
            return "Mutation contains \(actual) preconditions, exceeding the limit of \(maximum)"
        case .idempotencyEntryCorrupted:
            return "The stored idempotency entry is corrupted"
        case .invalidGraphPartitions(let reason):
            return "Mutation graph partitions are invalid: \(reason)"
        case .featureUnavailable(let reason):
            return "Mutation feature is unavailable: \(reason)"
        }
    }
}
