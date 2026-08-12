public enum StandaloneDatabaseOperationApplicationError: Error, Sendable,
    Equatable {
    case compiledContainerDefinition
    case schemaExecutionUnavailable
}
