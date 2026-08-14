import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
import DatabaseKit
@_spi(DatabaseExecution) import DatabaseWire

#if DATABASE_SERVER_MULTIPLE_BASES
public struct DatabaseOperationTargetKinds: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let database = Self(rawValue: 1 << 0)
    public static let base = Self(rawValue: 1 << 1)
    public static let composition = Self(rawValue: 1 << 2)

    public func accepts(_ target: DatabaseOperationTarget) -> Bool {
        switch target {
        case .database:
            return contains(.database)
        case .base:
            return contains(.base)
        case .composition:
            return contains(.composition)
        }
    }
}
#endif

public enum DatabaseOperationTransactionKind: Sendable, Hashable {
    case none
    case read
    case write
}

#if DATABASE_SERVER_MULTIPLE_BASES
public enum DatabaseBaseAdmissionKind: Sendable, Hashable {
    case activeData
    case administration
    case lifecycleJob
}
#endif

public struct DatabaseOperationRequirement: Sendable, Hashable {
    #if DATABASE_SERVER_MULTIPLE_BASES
    public let acceptedTargets: DatabaseOperationTargetKinds
    #endif
    public let access: Security.Access
    public let transaction: DatabaseOperationTransactionKind
    #if DATABASE_SERVER_MULTIPLE_BASES
    public let baseAdmission: DatabaseBaseAdmissionKind
    #endif
    #if DATABASE_SERVER_MULTIPLE_BASES
    public init(
        acceptedTargets: DatabaseOperationTargetKinds,
        access: Security.Access,
        transaction: DatabaseOperationTransactionKind,
        baseAdmission: DatabaseBaseAdmissionKind = .activeData
    ) {
        self.acceptedTargets = acceptedTargets
        self.access = access
        self.transaction = transaction
        self.baseAdmission = baseAdmission
    }
    #else
    public init(
        access: Security.Access,
        transaction: DatabaseOperationTransactionKind
    ) {
        self.access = access
        self.transaction = transaction
    }
    #endif

    package static func canonical(
        for identifier: DatabaseOperationIdentifier
    ) -> Self {
        #if DATABASE_SERVER_MULTIPLE_BASES
        let grantAndJobTargets: DatabaseOperationTargetKinds = [
            .database,
            .base,
        ]
        let queryTargets: DatabaseOperationTargetKinds = [
            .base,
            .composition,
        ]
        let dataTargets: DatabaseOperationTargetKinds = .base
        switch identifier {
        case .capabilitiesDescribe, .schemaDescribe:
            return Self(
                acceptedTargets: .database,
                access: .read,
                transaction: .read
            )
        case .schemaExecute, .baseExecute, .compositionExecute:
            return Self(
                acceptedTargets: .database,
                access: .administer,
                transaction: .write
            )
        case .grantExecute:
            return Self(
                acceptedTargets: grantAndJobTargets,
                access: .administer,
                transaction: .write,
                baseAdmission: .administration
            )
        case .queryExecute:
            return Self(
                acceptedTargets: queryTargets,
                access: .read,
                transaction: .read
            )
        case .mutationExecute:
            return Self(
                acceptedTargets: dataTargets,
                access: .write,
                transaction: .write
            )
        case .graphAlgorithm:
            return Self(
                acceptedTargets: dataTargets,
                access: .read,
                transaction: .read
            )
        case .ontologyExecute, .shaclExecute, .commandExecute,
             .maintenanceExecute:
            return Self(
                acceptedTargets: dataTargets,
                access: .administer,
                transaction: .write
            )
        case .jobStart:
            return Self(
                acceptedTargets: grantAndJobTargets,
                access: .administer,
                transaction: .write,
                baseAdmission: .administration
            )
        case .jobCancel:
            return Self(
                acceptedTargets: grantAndJobTargets,
                access: .administer,
                transaction: .write,
                baseAdmission: .lifecycleJob
            )
        case .jobStatus, .jobResult:
            return Self(
                acceptedTargets: grantAndJobTargets,
                access: .administer,
                transaction: .read,
                baseAdmission: .lifecycleJob
            )
        }
        #else
        switch identifier {
        case .capabilitiesDescribe, .schemaDescribe:
            return Self(
                access: .read,
                transaction: .read
            )
        case .schemaExecute:
            return Self(access: .administer, transaction: .write)
        case .queryExecute, .graphAlgorithm:
            return Self(access: .read, transaction: .read)
        case .mutationExecute:
            return Self(access: .write, transaction: .write)
        case .ontologyExecute, .shaclExecute, .commandExecute,
             .maintenanceExecute, .jobStart, .jobCancel:
            return Self(access: .administer, transaction: .write)
        case .jobStatus, .jobResult:
            return Self(access: .administer, transaction: .read)
        }
        #endif
    }
}
