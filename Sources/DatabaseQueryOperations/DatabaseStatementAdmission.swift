import DatabaseOperationCore
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import QueryAST
import DatabaseKit

/// Performs the non-replaceable admission path for statement execution.
package struct DatabaseStatementAdmission: Sendable {
    package let structuralLimits: QueryStructuralLimits

    package init(structuralLimits: QueryStructuralLimits) {
        self.structuralLimits = structuralLimits
    }

    package func admit(
        _ input: QueryInput,
        parameters: [QueryParameter]
    ) throws -> ValidatedDatabaseStatement {
        let parsed = try statement(from: input)
        let binder = try QueryParameterBinder(
            parameters: parameters,
            structuralLimits: structuralLimits
        )
        if case .select(let query) = parsed,
           !query.source.usesSPARQLSemantics {
            try binder.validate(parsed)
            return ValidatedDatabaseStatement(
                statement: parsed,
                structuralLimits: structuralLimits,
                parameters: parameters
            )
        }
        let bound = try binder.bind(parsed)
        try SPARQLSemanticValidator.validate(
            bound,
            limits: structuralLimits
        )
        return ValidatedDatabaseStatement(
            statement: bound,
            structuralLimits: structuralLimits,
            parameters: []
        )
    }

    private func statement(
        from input: QueryInput
    ) throws -> QueryStatement {
        switch input {
        case .statement(let statement):
            return statement
        case .block:
            throw DatabaseStatementAdmissionError.featureUnavailable("A block requires complete query execution")
        case .text(let language, let statement):
            switch language {
            case .sql:
                return try SQLParser(
                    structuralLimits: structuralLimits,
                    preservesCastOutputNames: true
                )
                    .parse(statement)
            case .sparql:
                #if DATABASE_QUERY_OPERATIONS_GRAPH_INDEXES
                return try SPARQLParser(structuralLimits: structuralLimits)
                    .parse(statement)
                #else
                _ = statement
                throw DatabaseStatementAdmissionError.featureUnavailable(
                    "SPARQL text requires the GraphIndexes package trait"
                )
                #endif
            }
        }
    }
}
