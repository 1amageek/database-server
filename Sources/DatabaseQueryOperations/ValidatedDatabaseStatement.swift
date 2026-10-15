import DatabaseOperationCore
import DatabaseKit

/// A statement admitted through canonical parsing, binding, and validation.
public struct ValidatedDatabaseStatement: Sendable {
    public let statement: QueryStatement
    public let structuralLimits: QueryStructuralLimits
    public let parameters: [QueryParameter]

    init(
        statement: QueryStatement,
        structuralLimits: QueryStructuralLimits,
        parameters: [QueryParameter]
    ) {
        self.statement = statement
        self.structuralLimits = structuralLimits
        self.parameters = parameters
    }
}
