public enum StandaloneDatabaseApplicationError: Error, Sendable,
    Equatable {
    case compiledContainerDefinition
    case schemaExecutionUnavailable
}
