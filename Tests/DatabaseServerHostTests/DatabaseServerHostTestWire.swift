@_spi(DatabaseExecution) import DatabaseWire
import DatabaseTypes

func databaseServerHostCapabilitiesRequest(
    requestID: UInt64
) throws -> ByteString {
    #if DATABASE_SERVER_HOST_MULTI_BASE
    return try DatabaseWireEncoder().encodeRequest(
        DatabaseOperationCatalog.capabilitiesDescribe,
        requestID: requestID,
        target: .database,
        request: EmptyOperationPayload()
    )
    #else
    return try DatabaseWireEncoder().encodeRequest(
        DatabaseOperationCatalog.capabilitiesDescribe,
        requestID: requestID,
        request: EmptyOperationPayload()
    )
    #endif
}
