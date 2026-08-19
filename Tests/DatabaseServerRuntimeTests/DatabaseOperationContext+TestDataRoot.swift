@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import TestSupport
@testable import DatabaseServerRuntime

#if MultiBase
typealias TestDataRootTarget = DatabaseOperationTarget

func testDataRootTarget() throws -> TestDataRootTarget {
    .base(try TestBaseEnvironment.id())
}
#else
enum TestDataRootTarget: Sendable {
    case database
}

func testDataRootTarget() throws -> TestDataRootTarget {
    .database
}
#endif

extension DatabaseOperationContext {
    static func testDataRoot(
        container: DBContainer,
        operation: DatabaseOperationIdentifier,
        requestID: UInt64,
        metadata: OperationRequestMetadata = OperationRequestMetadata(),
        authorization: AuthorizationContext = TestBaseEnvironment.authorization,
        jobAuthorizationReference: DatabaseJobAuthorizationReference? = nil,
        requestPayload: ByteString = [],
        dataContext: DatabaseContext? = nil,
        wireLimits: DatabaseWireLimits = .default
    ) -> DatabaseOperationContext {
        testDataRoot(
            container: container,
            requirement: .canonical(for: operation),
            requestID: requestID,
            metadata: metadata,
            authorization: authorization,
            jobAuthorizationReference: jobAuthorizationReference,
            requestPayload: requestPayload,
            dataContext: dataContext,
            wireLimits: wireLimits
        )
    }

    static func testDataRoot(
        container: DBContainer,
        requirement: DatabaseOperationRequirement,
        requestID: UInt64,
        metadata: OperationRequestMetadata = OperationRequestMetadata(),
        authorization: AuthorizationContext = TestBaseEnvironment.authorization,
        jobAuthorizationReference: DatabaseJobAuthorizationReference? = nil,
        requestPayload: ByteString = [],
        dataContext: DatabaseContext? = nil,
        wireLimits: DatabaseWireLimits = .default
    ) -> DatabaseOperationContext {
#if MultiBase
        let context = dataContext ?? container.testBaseContext()
        return DatabaseOperationContext(
            container: container,
            target: .base(context.baseID),
            baseContext: context,
            composition: nil,
            requirement: requirement,
            requestID: requestID,
            metadata: metadata,
            authorization: authorization,
            jobAuthorizationReference: jobAuthorizationReference,
            requestPayload: requestPayload,
            wireLimits: wireLimits
        )
#else
        _ = dataContext
        return DatabaseOperationContext(
            container: container,
            requirement: requirement,
            requestID: requestID,
            metadata: metadata,
            authorization: authorization,
            jobAuthorizationReference: jobAuthorizationReference,
            requestPayload: requestPayload,
            wireLimits: wireLimits
        )
#endif
    }
}
