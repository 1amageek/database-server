import DatabaseKit
import DatabaseOperationCore
import StorageKit

/// Derives checkpoint ceilings from the already admitted request resources.
package enum SQLCheckpointPolicy {
    package static func limits(
        for budget: ExecutionBudget,
        structuralLimits: QueryStructuralLimits,
        ceiling: TransactionCheckpointLimits?
    ) throws -> TransactionCheckpointLimits {
        func integer(_ value: UInt64, limit: DatabaseOperationConfigurationError.Limit) throws -> Int {
            guard let result = Int(exactly: value) else {
                throw DatabaseOperationConfigurationError.unsupportedOnCurrentPlatform(
                    limit: limit, actual: value, maximum: UInt64(Int.max))
            }
            return result
        }
        let work = try integer(budget.maximumWorkUnits, limit: .maximumWorkUnits)
        let bytes = try integer(budget.maximumIntermediateBytes, limit: .maximumIntermediateBytes)
        let rows = try integer(UInt64(budget.maximumIntermediateRows), limit: .maximumIntermediateRows)
        let depth = try integer(min(structuralLimits.maximumCollectionElements, budget.maximumWorkUnits),
            limit: .maximumCollectionElements)
        return try TransactionCheckpointLimits(
            maximumEntries: min(work, ceiling?.maximumEntries ?? work),
            maximumDepth: min(depth, ceiling?.maximumDepth ?? depth),
            maximumRetainedBytes: min(bytes, ceiling?.maximumRetainedBytes ?? bytes),
            maximumWorkUnits: min(work, ceiling?.maximumWorkUnits ?? work),
            maximumReadPageRows: min(rows, ceiling?.maximumReadPageRows ?? rows)
        )
    }
}
