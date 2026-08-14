import DatabaseKit
@_spi(DatabaseExecution) import DatabaseWire

/// State-independent request metadata evaluated before extensible dispatch.
public struct DatabaseOperationAdmissionRequest: Sendable, Hashable {
    public let requestID: UInt64
    public let operation: DatabaseOperationIdentifier
    #if DATABASE_SERVER_MULTIPLE_BASES
    public let target: DatabaseOperationTarget
    #endif
    public let metadata: OperationRequestMetadata
    public let authorization: AuthorizationContext

    #if DATABASE_SERVER_MULTIPLE_BASES
    public init(
        requestID: UInt64,
        operation: DatabaseOperationIdentifier,
        target: DatabaseOperationTarget,
        metadata: OperationRequestMetadata,
        authorization: AuthorizationContext
    ) {
        self.requestID = requestID
        self.operation = operation
        self.target = target
        self.metadata = metadata
        self.authorization = authorization
    }
    #else
    public init(
        requestID: UInt64,
        operation: DatabaseOperationIdentifier,
        metadata: OperationRequestMetadata,
        authorization: AuthorizationContext
    ) {
        self.requestID = requestID
        self.operation = operation
        self.metadata = metadata
        self.authorization = authorization
    }
    #endif
}
