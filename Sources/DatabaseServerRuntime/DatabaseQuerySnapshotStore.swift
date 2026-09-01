import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import StorageKit

#if DATABASE_SERVER_MULTI_BASE
private typealias DatabaseSnapshotCompositionMembers = [Base.ID]
#else
private struct DatabaseSnapshotCompositionMembers: Sendable {}
#endif

/// Durable fixed-result paging for query results whose storage read point
/// cannot be restored across independent requests.
package struct DatabaseQuerySnapshotStore: Sendable {
    #if DATABASE_SERVER_MULTI_BASE
    fileprivate enum Target: Sendable, Equatable {
        case resource(Security.Resource, generation: UInt64)
        case composition(
            CompositionResolution,
            basePlacementGenerations: [Base.ID: UInt64]
        )

        func hasSameIdentity(as other: Self) -> Bool {
            switch (self, other) {
            case (.resource(let lhs, _), .resource(let rhs, _)):
                return lhs == rhs
            case (.composition(let lhs, _), .composition(let rhs, _)):
                switch (lhs.kind, rhs.kind) {
                case (.named, .named):
                    guard let lhsID = lhs.namedID,
                          let rhsID = rhs.namedID else {
                        return false
                    }
                    return lhsID == rhsID
                case (.derived, .derived):
                    return lhs.bases == rhs.bases
                default:
                    return false
                }
            default:
                return false
            }
        }

        func encode(
            to encoder: inout DatabaseServerFrameEncoder
        ) throws(StorageFrameError) {
            switch self {
            case .resource(.database, let generation):
                encoder.writeUInt8(0)
                encoder.writeUInt64(generation)
            case .resource(.base(let id), let generation):
                encoder.writeUInt8(1)
                try encoder.writeString(id.value)
                encoder.writeUInt64(generation)
            case .composition(let composition, let baseGenerations):
                encoder.writeUInt8(2)
                switch composition.kind {
                case .named:
                    guard let id = composition.namedID,
                          let generation = composition.generation else {
                        throw .invalidValue
                    }
                    encoder.writeUInt8(0)
                    try encoder.writeString(id.value)
                    encoder.writeUInt64(generation)
                case .derived:
                    encoder.writeUInt8(1)
                }
                try encoder.writeCount(composition.bases.count)
                for baseID in composition.bases {
                    try encoder.writeString(baseID.value)
                    guard let generation = baseGenerations[baseID] else {
                        throw .invalidValue
                    }
                    encoder.writeUInt64(generation)
                }
            }
        }

        init(from decoder: inout DatabaseServerFrameDecoder) throws(StorageFrameError) {
            let kind = try decoder.readUInt8()
            do {
                switch kind {
                case 0:
                    self = .resource(
                        .database,
                        generation: try decoder.readUInt64()
                    )
                case 1:
                    self = .resource(
                        .base(try Base.ID(decoder.readString())),
                        generation: try decoder.readUInt64()
                    )
                case 2:
                    let compositionKind = try decoder.readUInt8()
                    let id: Base.Composition.ID?
                    let generation: UInt64?
                    switch compositionKind {
                    case 0:
                        id = try Base.Composition.ID(decoder.readString())
                        generation = try decoder.readUInt64()
                    case 1:
                        id = nil
                        generation = nil
                    default:
                        throw StorageFrameError.invalidValue
                    }
                    let count = try decoder.readCount()
                    var bases: [Base.ID] = []
                    var baseGenerations: [Base.ID: UInt64] = [:]
                    bases.reserveCapacity(count)
                    baseGenerations.reserveCapacity(count)
                    for _ in 0..<count {
                        let baseID = try Base.ID(decoder.readString())
                        guard baseGenerations[baseID] == nil else {
                            throw StorageFrameError.invalidValue
                        }
                        bases.append(baseID)
                        baseGenerations[baseID] = try decoder.readUInt64()
                    }
                    if let id, let generation {
                        self = .composition(
                            try .named(
                                id: id,
                                generation: generation,
                                bases: bases
                            ),
                            basePlacementGenerations: baseGenerations
                        )
                    } else {
                        self = .composition(
                            try .derived(bases),
                            basePlacementGenerations: baseGenerations
                        )
                    }
                default:
                    throw StorageFrameError.invalidValue
                }
            } catch let error as StorageFrameError {
                throw error
            } catch {
                throw .invalidValue
            }
            switch self {
            case .resource(.database, _):
                break
            case .resource(.base, let generation):
                guard generation > 0 else { throw .invalidValue }
            case .composition(let composition, let baseGenerations):
                guard baseGenerations.count == composition.bases.count,
                      composition.bases.allSatisfy({
                          baseGenerations[$0].map { $0 > 0 } == true
                      }) else {
                    throw .invalidValue
                }
            }
        }
    }
    #else
    fileprivate enum Target: Sendable, Equatable {
        case database(generation: UInt64)

        func hasSameIdentity(as other: Self) -> Bool {
            _ = other
            return true
        }

        func encode(
            to encoder: inout DatabaseServerFrameEncoder
        ) throws(StorageFrameError) {
            guard case .database(let generation) = self else {
                throw .invalidValue
            }
            encoder.writeUInt8(0)
            encoder.writeUInt64(generation)
        }

        init(
            from decoder: inout DatabaseServerFrameDecoder
        ) throws(StorageFrameError) {
            guard try decoder.readUInt8() == 0 else {
                throw .invalidValue
            }
            self = .database(generation: try decoder.readUInt64())
        }
    }
    #endif

    package func beginWrite(
        for lease: DatabaseExecutionStorage,
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext
    ) async throws -> WriteReservation {
        #if DATABASE_SERVER_MULTI_BASE
        return try await beginWrite(
            resource: lease.resource,
            dataGeneration: lease.generation,
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization
        )
        #else
        return try await beginWrite(
            dataGeneration: lease.generation,
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization
        )
        #endif
    }

    package struct WriteReservation: Sendable {
        package let snapshotID: ByteString
        fileprivate let principalDigest: ByteString
        fileprivate let slot: UInt8
        fileprivate let expiresAt: Timestamp
        fileprivate let target: Target
        fileprivate let schemaGeneration: UInt64
        fileprivate let queryFingerprint: ByteString

        package func continuation(pageID: ByteString) -> ByteString {
            ByteString([DatabaseQuerySnapshotStore.continuationMarker])
                .appending(contentsOf: snapshotID)
                .appending(contentsOf: pageID)
        }
    }

    package struct HistoricalQueryContinuation: Sendable {
        package let readVersion: UInt64
        package let continuation: QueryContinuation
        fileprivate let snapshotID: ByteString
        fileprivate let stepID: ByteString
        fileprivate let manifest: HistoricalManifest
        fileprivate let step: HistoricalQueryStep
    }

    package struct HistoricalGraphContinuation: Sendable {
        package let readVersion: UInt64
        package let resultFingerprint: ByteString
        package let offset: UInt64
        fileprivate let snapshotID: ByteString
        fileprivate let stepID: ByteString
        fileprivate let manifest: HistoricalManifest
        fileprivate let step: HistoricalGraphStep
    }

    private struct Manifest: DatabaseServerFrameValue, Equatable {
        let target: Target
        let schemaGeneration: UInt64
        let principalDigest: ByteString
        let queryFingerprint: ByteString
        let expiresAt: Timestamp
        let slot: UInt8
        let pageCount: UInt32
        let totalPayloadBytes: UInt64

        func encode(
            to encoder: inout DatabaseServerFrameEncoder
        ) throws(StorageFrameError) {
            try target.encode(to: &encoder)
            encoder.writeUInt64(schemaGeneration)
            try encoder.writeBytes(principalDigest)
            try encoder.writeBytes(queryFingerprint)
            encoder.writeInt64(expiresAt.secondsSinceUnixEpoch)
            encoder.writeUInt32(expiresAt.nanoseconds)
            encoder.writeUInt8(slot)
            encoder.writeUInt32(pageCount)
            encoder.writeUInt64(totalPayloadBytes)
        }

        init(
            from decoder: inout DatabaseServerFrameDecoder
        ) throws(StorageFrameError) {
            target = try Target(from: &decoder)
            schemaGeneration = try decoder.readUInt64()
            principalDigest = try decoder.readBytes()
            queryFingerprint = try decoder.readBytes()
            do {
                expiresAt = try Timestamp(
                    secondsSinceUnixEpoch: decoder.readInt64(),
                    nanoseconds: decoder.readUInt32()
                )
            } catch {
                throw .invalidTimestamp
            }
            slot = try decoder.readUInt8()
            pageCount = try decoder.readUInt32()
            totalPayloadBytes = try decoder.readUInt64()
            guard principalDigest.count == 32,
                  queryFingerprint.count == 32,
                  slot < DatabaseQuerySnapshotStore.maximumActiveCount,
                  pageCount > 0,
                  totalPayloadBytes > 0,
                  totalPayloadBytes
                    <= DatabaseQuerySnapshotStore.maximumSpoolBytes
            else {
                throw .invalidValue
            }
        }

        init(
            target: Target,
            schemaGeneration: UInt64,
            principalDigest: ByteString,
            queryFingerprint: ByteString,
            expiresAt: Timestamp,
            slot: UInt8,
            pageCount: UInt32,
            totalPayloadBytes: UInt64
        ) {
            self.target = target
            self.schemaGeneration = schemaGeneration
            self.principalDigest = principalDigest
            self.queryFingerprint = queryFingerprint
            self.expiresAt = expiresAt
            self.slot = slot
            self.pageCount = pageCount
            self.totalPayloadBytes = totalPayloadBytes
        }
    }

    /// Marks the one page whose successful replay completed this snapshot.
    /// The page remains durable until expiry so the opaque terminal token can
    /// be replayed, while the principal slot is no longer active.
    private struct TerminalRecord: DatabaseServerFrameValue, Equatable {
        let pageID: ByteString

        func encode(
            to encoder: inout DatabaseServerFrameEncoder
        ) throws(StorageFrameError) {
            try encoder.writeBytes(pageID)
        }

        init(
            from decoder: inout DatabaseServerFrameDecoder
        ) throws(StorageFrameError) {
            pageID = try decoder.readBytes()
            guard pageID.count == 16 else {
                throw .invalidValue
            }
        }

        init(pageID: ByteString) {
            self.pageID = pageID
        }
    }

    fileprivate enum HistoricalKind: UInt8, Sendable, Equatable {
        case query = 1
        case graph = 2
    }

    private struct HistoricalTerminal: DatabaseServerFrameValue, Equatable {
        let kind: HistoricalKind
        let stepID: ByteString

        func encode(
            to encoder: inout DatabaseServerFrameEncoder
        ) throws(StorageFrameError) {
            encoder.writeUInt8(kind.rawValue)
            try encoder.writeBytes(stepID)
        }

        init(
            from decoder: inout DatabaseServerFrameDecoder
        ) throws(StorageFrameError) {
            guard let kind = HistoricalKind(
                rawValue: try decoder.readUInt8()
            ) else {
                throw .invalidValue
            }
            self.kind = kind
            self.stepID = try decoder.readBytes()
            guard stepID.count == 16 else {
                throw .invalidValue
            }
        }

        init(kind: HistoricalKind, stepID: ByteString) {
            self.kind = kind
            self.stepID = stepID
        }
    }

    fileprivate struct HistoricalManifest: DatabaseServerFrameValue, Equatable {
        let kind: HistoricalKind
        let target: Target
        let schemaGeneration: UInt64
        let principalDigest: ByteString
        let queryFingerprint: ByteString
        let expiresAt: Timestamp
        let slot: UInt8

        func encode(
            to encoder: inout DatabaseServerFrameEncoder
        ) throws(StorageFrameError) {
            encoder.writeUInt8(kind.rawValue)
            try target.encode(to: &encoder)
            encoder.writeUInt64(schemaGeneration)
            try encoder.writeBytes(principalDigest)
            try encoder.writeBytes(queryFingerprint)
            encoder.writeInt64(expiresAt.secondsSinceUnixEpoch)
            encoder.writeUInt32(expiresAt.nanoseconds)
            encoder.writeUInt8(slot)
        }

        init(
            from decoder: inout DatabaseServerFrameDecoder
        ) throws(StorageFrameError) {
            guard let kind = HistoricalKind(
                rawValue: try decoder.readUInt8()
            ) else {
                throw .invalidValue
            }
            self.kind = kind
            self.target = try Target(from: &decoder)
            self.schemaGeneration = try decoder.readUInt64()
            self.principalDigest = try decoder.readBytes()
            self.queryFingerprint = try decoder.readBytes()
            do {
                self.expiresAt = try Timestamp(
                    secondsSinceUnixEpoch: decoder.readInt64(),
                    nanoseconds: decoder.readUInt32()
                )
            } catch {
                throw .invalidTimestamp
            }
            self.slot = try decoder.readUInt8()
            guard principalDigest.count == 32,
                  queryFingerprint.count == 32,
                  slot < DatabaseQuerySnapshotStore.maximumActiveCount
            else {
                throw .invalidValue
            }
        }

        init(
            kind: HistoricalKind,
            target: Target,
            schemaGeneration: UInt64,
            principalDigest: ByteString,
            queryFingerprint: ByteString,
            expiresAt: Timestamp,
            slot: UInt8
        ) {
            self.kind = kind
            self.target = target
            self.schemaGeneration = schemaGeneration
            self.principalDigest = principalDigest
            self.queryFingerprint = queryFingerprint
            self.expiresAt = expiresAt
            self.slot = slot
        }
    }

    fileprivate struct HistoricalQueryStep: DatabaseServerFrameValue, Equatable {
        let readVersion: UInt64
        let continuation: ByteString
        let successorID: ByteString?

        func encode(
            to encoder: inout DatabaseServerFrameEncoder
        ) throws(StorageFrameError) {
            encoder.writeUInt64(readVersion)
            try encoder.writeBytes(continuation)
            encoder.writeUInt8(successorID == nil ? 0 : 1)
            if let successorID {
                try encoder.writeBytes(successorID)
            }
        }

        init(
            from decoder: inout DatabaseServerFrameDecoder
        ) throws(StorageFrameError) {
            self.readVersion = try decoder.readUInt64()
            self.continuation = try decoder.readBytes()
            switch try decoder.readUInt8() {
            case 0:
                self.successorID = nil
            case 1:
                self.successorID = try decoder.readBytes()
            default:
                throw .invalidValue
            }
            guard !continuation.isEmpty,
                  continuation.count
                    <= DatabaseQuerySnapshotStore.maximumHistoricalStateBytes,
                  successorID == nil || successorID?.count == 16
            else {
                throw .invalidValue
            }
        }

        /// Whether this stored record still describes the step a caller
        /// captured in its continuation handle.
        ///
        /// A handle is captured before the step is linked to a successor, and
        /// that link is written exactly once, so a replayed advance must
        /// compare the caller-visible state and accept a successor the caller
        /// has not observed yet.
        func describesSameStep(as held: HistoricalQueryStep) -> Bool {
            readVersion == held.readVersion
                && continuation == held.continuation
                && (held.successorID == nil
                    || held.successorID == successorID)
        }

        init(
            readVersion: UInt64,
            continuation: ByteString,
            successorID: ByteString? = nil
        ) {
            self.readVersion = readVersion
            self.continuation = continuation
            self.successorID = successorID
        }
    }

    fileprivate struct HistoricalGraphStep: DatabaseServerFrameValue, Equatable {
        let readVersion: UInt64
        let resultFingerprint: ByteString
        let offset: UInt64
        let successorID: ByteString?

        func encode(
            to encoder: inout DatabaseServerFrameEncoder
        ) throws(StorageFrameError) {
            encoder.writeUInt64(readVersion)
            try encoder.writeBytes(resultFingerprint)
            encoder.writeUInt64(offset)
            encoder.writeUInt8(successorID == nil ? 0 : 1)
            if let successorID {
                try encoder.writeBytes(successorID)
            }
        }

        init(
            from decoder: inout DatabaseServerFrameDecoder
        ) throws(StorageFrameError) {
            self.readVersion = try decoder.readUInt64()
            self.resultFingerprint = try decoder.readBytes()
            self.offset = try decoder.readUInt64()
            switch try decoder.readUInt8() {
            case 0:
                self.successorID = nil
            case 1:
                self.successorID = try decoder.readBytes()
            default:
                throw .invalidValue
            }
            guard resultFingerprint.count == DatabaseRequestDigest.byteCount,
                  offset > 0,
                  successorID == nil || successorID?.count == 16
            else {
                throw .invalidValue
            }
        }

        /// Whether this stored record still describes the step a caller
        /// captured in its continuation handle.
        ///
        /// A handle is captured before the step is linked to a successor, and
        /// that link is written exactly once, so a replayed advance must
        /// compare the caller-visible state and accept a successor the caller
        /// has not observed yet.
        func describesSameStep(as held: HistoricalGraphStep) -> Bool {
            readVersion == held.readVersion
                && resultFingerprint == held.resultFingerprint
                && offset == held.offset
                && (held.successorID == nil
                    || held.successorID == successorID)
        }

        init(
            readVersion: UInt64,
            resultFingerprint: ByteString,
            offset: UInt64,
            successorID: ByteString? = nil
        ) {
            self.readVersion = readVersion
            self.resultFingerprint = resultFingerprint
            self.offset = offset
            self.successorID = successorID
        }
    }

    private struct HistoricalUsage: DatabaseServerFrameValue, Equatable {
        let storedStepBytes: UInt64

        func encode(
            to encoder: inout DatabaseServerFrameEncoder
        ) throws(StorageFrameError) {
            encoder.writeUInt64(storedStepBytes)
        }

        init(
            from decoder: inout DatabaseServerFrameDecoder
        ) throws(StorageFrameError) {
            self.storedStepBytes = try decoder.readUInt64()
            guard storedStepBytes > 0,
                  storedStepBytes
                    <= DatabaseQuerySnapshotStore.maximumSpoolBytes else {
                throw .invalidValue
            }
        }

        init(storedStepBytes: UInt64) {
            self.storedStepBytes = storedStepBytes
        }
    }

    private struct PageDescriptor: DatabaseServerFrameValue {
        let chunkCount: UInt32
        let payloadByteCount: UInt64
        let digest: ByteString

        func encode(
            to encoder: inout DatabaseServerFrameEncoder
        ) throws(StorageFrameError) {
            encoder.writeUInt32(chunkCount)
            encoder.writeUInt64(payloadByteCount)
            try encoder.writeBytes(digest)
        }

        init(
            from decoder: inout DatabaseServerFrameDecoder
        ) throws(StorageFrameError) {
            chunkCount = try decoder.readUInt32()
            payloadByteCount = try decoder.readUInt64()
            digest = try decoder.readBytes()
            guard chunkCount > 0,
                  payloadByteCount > 0,
                  payloadByteCount
                    <= DatabaseQuerySnapshotStore.maximumSpoolBytes,
                  digest.count == 32 else {
                throw .invalidValue
            }
        }

        init(
            chunkCount: UInt32,
            payloadByteCount: UInt64,
            digest: ByteString
        ) {
            self.chunkCount = chunkCount
            self.payloadByteCount = payloadByteCount
            self.digest = digest
        }
    }

    private struct PrincipalSlot: DatabaseServerFrameValue {
        let snapshotID: ByteString
        let expiresAt: Timestamp

        func encode(
            to encoder: inout DatabaseServerFrameEncoder
        ) throws(StorageFrameError) {
            try encoder.writeBytes(snapshotID)
            encoder.writeInt64(expiresAt.secondsSinceUnixEpoch)
            encoder.writeUInt32(expiresAt.nanoseconds)
        }

        init(
            from decoder: inout DatabaseServerFrameDecoder
        ) throws(StorageFrameError) {
            snapshotID = try decoder.readBytes()
            do {
                expiresAt = try Timestamp(
                    secondsSinceUnixEpoch: decoder.readInt64(),
                    nanoseconds: decoder.readUInt32()
                )
            } catch {
                throw .invalidTimestamp
            }
            guard snapshotID.count == 16 else {
                throw .invalidValue
            }
        }

        init(snapshotID: ByteString, expiresAt: Timestamp) {
            self.snapshotID = snapshotID
            self.expiresAt = expiresAt
        }
    }

    private struct PendingSnapshot: DatabaseServerFrameValue {
        let principalDigest: ByteString
        let slot: UInt8
        let expiresAt: Timestamp

        func encode(
            to encoder: inout DatabaseServerFrameEncoder
        ) throws(StorageFrameError) {
            try encoder.writeBytes(principalDigest)
            encoder.writeUInt8(slot)
            encoder.writeInt64(expiresAt.secondsSinceUnixEpoch)
            encoder.writeUInt32(expiresAt.nanoseconds)
        }

        init(
            from decoder: inout DatabaseServerFrameDecoder
        ) throws(StorageFrameError) {
            principalDigest = try decoder.readBytes()
            slot = try decoder.readUInt8()
            do {
                expiresAt = try Timestamp(
                    secondsSinceUnixEpoch: decoder.readInt64(),
                    nanoseconds: decoder.readUInt32()
                )
            } catch {
                throw .invalidTimestamp
            }
            guard principalDigest.count == 32,
                  slot < DatabaseQuerySnapshotStore.maximumActiveCount
            else {
                throw .invalidValue
            }
        }

        init(
            principalDigest: ByteString,
            slot: UInt8,
            expiresAt: Timestamp
        ) {
            self.principalDigest = principalDigest
            self.slot = slot
            self.expiresAt = expiresAt
        }
    }

    private struct PageReservation: DatabaseServerFrameValue {
        let marker: UInt8

        func encode(
            to encoder: inout DatabaseServerFrameEncoder
        ) throws(StorageFrameError) {
            encoder.writeUInt8(marker)
        }

        init(
            from decoder: inout DatabaseServerFrameDecoder
        ) throws(StorageFrameError) {
            marker = try decoder.readUInt8()
            guard marker == 1 else { throw .invalidValue }
        }

        init() {
            marker = 1
        }
    }

    private struct ExpiryRecord: DatabaseServerFrameValue {
        let snapshotID: ByteString
        let principalDigest: ByteString
        let slot: UInt8
        let expiresAt: Timestamp

        func encode(
            to encoder: inout DatabaseServerFrameEncoder
        ) throws(StorageFrameError) {
            try encoder.writeBytes(snapshotID)
            try encoder.writeBytes(principalDigest)
            encoder.writeUInt8(slot)
            encoder.writeInt64(expiresAt.secondsSinceUnixEpoch)
            encoder.writeUInt32(expiresAt.nanoseconds)
        }

        init(
            from decoder: inout DatabaseServerFrameDecoder
        ) throws(StorageFrameError) {
            snapshotID = try decoder.readBytes()
            principalDigest = try decoder.readBytes()
            slot = try decoder.readUInt8()
            do {
                expiresAt = try Timestamp(
                    secondsSinceUnixEpoch: decoder.readInt64(),
                    nanoseconds: decoder.readUInt32()
                )
            } catch {
                throw .invalidTimestamp
            }
            guard snapshotID.count == 16,
                  principalDigest.count == 32,
                  slot < DatabaseQuerySnapshotStore.maximumActiveCount
            else {
                throw .invalidValue
            }
        }

        init(
            snapshotID: ByteString,
            principalDigest: ByteString,
            slot: UInt8,
            expiresAt: Timestamp
        ) {
            self.snapshotID = snapshotID
            self.principalDigest = principalDigest
            self.slot = slot
            self.expiresAt = expiresAt
        }
    }

    private static let snapshotLifetimeSeconds: Int64 = 15 * 60
    private static let chunkByteCount = 60 * 1_024
    private static let maximumActiveCount: UInt8 = 8
    package static let maximumSpoolBytes: UInt64 = 16 * 1_024 * 1_024
    private static let maximumHistoricalStateBytes = 4 * 1_024
    package static let continuationMarker: UInt8 = 0x51
    package static let continuationByteCount = 33

    private let container: DBContainer
    private let clock: AnyDatabaseWallClock
    private let identifierGenerator: AnyDatabaseUUIDGenerator
    private let scheduler: AnyDatabaseJobScheduler
    private let wireLimits: DatabaseWireLimits
    private let historicalStorageByteLimit: UInt64
    private let snapshots: Subspace
    private let principalSlots: Subspace
    private let expirations: Subspace

    package var controlContainer: DBContainer { container }

    package init(
        container: DBContainer,
        clock: AnyDatabaseWallClock,
        identifierGenerator: AnyDatabaseUUIDGenerator,
        scheduler: AnyDatabaseJobScheduler,
        wireLimits: DatabaseWireLimits,
        historicalStorageByteLimit: UInt64 = maximumSpoolBytes
    ) {
        precondition(
            historicalStorageByteLimit > 0
                && historicalStorageByteLimit <= Self.maximumSpoolBytes
        )
        self.container = container
        self.clock = clock
        self.identifierGenerator = identifierGenerator
        self.scheduler = scheduler
        self.wireLimits = wireLimits
        self.historicalStorageByteLimit = historicalStorageByteLimit
        let root = container.controlStorage().systemRoot.subspace("query-snapshots")
        self.snapshots = root.subspace("snapshots")
        self.principalSlots = root.subspace("principals")
        self.expirations = root.subspace("expirations")
    }

    #if DATABASE_SERVER_MULTI_BASE
    package func beginWrite(
        resource: Security.Resource,
        dataGeneration: UInt64,
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext
    ) async throws -> WriteReservation {
        try await beginWrite(
            target: .resource(resource, generation: dataGeneration),
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization
        )
    }
    #else
    package func beginWrite(
        dataGeneration: UInt64,
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext
    ) async throws -> WriteReservation {
        try await beginWrite(
            target: .database(generation: dataGeneration),
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization
        )
    }
    #endif

    func load(
        continuation: ByteString,
        lease: DatabaseExecutionStorage,
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext
    ) async throws -> QueryRowPage {
        #if DATABASE_SERVER_MULTI_BASE
        return try await load(
            continuation: continuation,
            resource: lease.resource,
            dataGeneration: lease.generation,
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization
        )
        #else
        return try await load(
            continuation: continuation,
            dataGeneration: lease.generation,
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization
        )
        #endif
    }

    func loadRDFGraph(
        continuation: ByteString,
        lease: DatabaseExecutionStorage,
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext
    ) async throws -> RDFGraphPage {
        #if DATABASE_SERVER_MULTI_BASE
        return try await loadRDFGraph(
            continuation: continuation,
            resource: lease.resource,
            dataGeneration: lease.generation,
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization
        )
        #else
        return try await loadRDFGraph(
            continuation: continuation,
            dataGeneration: lease.generation,
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization
        )
        #endif
    }

    #if DATABASE_SERVER_MULTI_BASE
    package func beginWrite(
        composition: CompositionResolution,
        basePlacementGenerations: [Base.ID: UInt64],
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext
    ) async throws -> WriteReservation {
        try await beginWrite(
            target: .composition(
                composition,
                basePlacementGenerations: basePlacementGenerations
            ),
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization
        )
    }
    #endif

    private func beginWrite(
        target: Target,
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext
    ) async throws -> WriteReservation {
        guard Self.isValid(target: target),
              queryFingerprint.count == 32,
              authorization.principal != nil else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        let principalDigest = try authorizationDigest(authorization)
        let now = clock.now
        let expiresAt = try Self.addingLifetime(to: now)

        // Arm cleanup before publishing any durable state. A wake-up with no
        // matching snapshot is harmless, while reserving first would leave a
        // crash window in which no process is responsible for cleanup.
        try await scheduler.ensureWakeUp(noLaterThan: expiresAt)

        for _ in 0..<16 {
            let snapshotID = Self.identifierBytes(
                identifierGenerator.generate()
            )
            guard let pending = try await reserve(
                snapshotID: snapshotID,
                principalDigest: principalDigest,
                expiresAt: expiresAt,
                now: now
            ) else {
                continue
            }
            return WriteReservation(
                snapshotID: snapshotID,
                principalDigest: principalDigest,
                slot: pending.slot,
                expiresAt: expiresAt,
                target: target,
                schemaGeneration: schemaGeneration,
                queryFingerprint: queryFingerprint
            )
        }
        throw DatabaseQueryExecutionError.querySnapshotUnavailable(
            "unable to reserve a unique opaque snapshot identifier"
        )
    }

    private static func isValid(target: Target) -> Bool {
        #if DATABASE_SERVER_MULTI_BASE
        switch target {
        case .resource(.database, _):
            return true
        case .resource(.base, let generation):
            return generation > 0
        case .composition(let composition, let baseGenerations):
            return !composition.bases.isEmpty
                && baseGenerations.count == composition.bases.count
                && composition.bases.allSatisfy {
                    baseGenerations[$0].map { $0 > 0 } == true
                }
        }
        #else
        guard case .database = target else { return false }
        return true
        #endif
    }

    package func canPersistHistoricalContinuation(
        _ continuation: QueryContinuation
    ) -> Bool {
        !continuation.bytes.isEmpty
            && continuation.bytes.count <= Self.maximumHistoricalStateBytes
    }

    package func publishHistoricalQuery(
        _ continuation: QueryContinuation,
        readVersion: UInt64,
        in reservation: WriteReservation
    ) async throws -> ByteString {
        guard canPersistHistoricalContinuation(continuation),
              Int64(exactly: readVersion) != nil else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        let stepID = Self.identifierBytes(identifierGenerator.generate())
        try await publishHistorical(
            reservation: reservation,
            kind: .query,
            stepID: stepID,
            step: HistoricalQueryStep(
                readVersion: readVersion,
                continuation: continuation.bytes
            )
        )
        return reservation.continuation(pageID: stepID)
    }

    package func publishHistoricalGraph(
        readVersion: UInt64,
        resultFingerprint: ByteString,
        offset: UInt64,
        in reservation: WriteReservation
    ) async throws -> ByteString {
        guard Int64(exactly: readVersion) != nil,
              resultFingerprint.count == DatabaseRequestDigest.byteCount,
              offset > 0 else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        let stepID = Self.identifierBytes(identifierGenerator.generate())
        try await publishHistorical(
            reservation: reservation,
            kind: .graph,
            stepID: stepID,
            step: HistoricalGraphStep(
                readVersion: readVersion,
                resultFingerprint: resultFingerprint,
                offset: offset
            )
        )
        return reservation.continuation(pageID: stepID)
    }

    private func publishHistorical<Step: DatabaseServerFrameValue>(
        reservation: WriteReservation,
        kind: HistoricalKind,
        stepID: ByteString,
        step: Step
    ) async throws {
        let encodedStep = try DatabaseServerFrameCodec.encode(step)
        guard let storedStepBytes = UInt64(exactly: encodedStep.count),
              storedStepBytes <= historicalStorageByteLimit else {
            throw DatabaseQueryExecutionError
                .querySnapshotStorageLimitExceeded(
                    maximumBytes: historicalStorageByteLimit
                )
        }
        try await withControlAccess { transaction in
            try await self.validateCurrentTarget(
                reservation.target,
                transaction: transaction
            )
            guard try await self.validatePending(
                reservation,
                transaction: transaction
            ),
                  try await transaction.getValue(
                    for: self.manifestKey(reservation.snapshotID),
                    snapshot: false
                  ) == nil,
                  try await transaction.getValue(
                    for: self.historicalManifestKey(reservation.snapshotID),
                    snapshot: false
                  ) == nil,
                  try await transaction.getValue(
                    for: self.historicalStepKey(
                        snapshotID: reservation.snapshotID,
                        stepID: stepID
                    ),
                    snapshot: false
                  ) == nil,
                  try await transaction.getValue(
                    for: self.historicalUsageKey(reservation.snapshotID),
                    snapshot: false
                  ) == nil else {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            let manifest = HistoricalManifest(
                kind: kind,
                target: reservation.target,
                schemaGeneration: reservation.schemaGeneration,
                principalDigest: reservation.principalDigest,
                queryFingerprint: reservation.queryFingerprint,
                expiresAt: reservation.expiresAt,
                slot: reservation.slot
            )
            try transaction.setValue(
                DatabaseServerFrameCodec.encode(manifest),
                for: self.historicalManifestKey(reservation.snapshotID)
            )
            try transaction.setValue(
                encodedStep,
                for: self.historicalStepKey(
                    snapshotID: reservation.snapshotID,
                    stepID: stepID
                )
            )
            try transaction.setValue(
                DatabaseServerFrameCodec.encode(
                    HistoricalUsage(storedStepBytes: storedStepBytes)
                ),
                for: self.historicalUsageKey(reservation.snapshotID)
            )
            try transaction.clear(key: self.pendingKey(reservation.snapshotID))
        }
    }

    package func loadHistoricalQuery(
        continuation: ByteString,
        lease: DatabaseExecutionStorage,
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext
    ) async throws -> HistoricalQueryContinuation? {
        #if DATABASE_SERVER_MULTI_BASE
        let target = Target.resource(
            lease.resource,
            generation: lease.generation
        )
        #else
        let target = Target.database(generation: lease.generation)
        #endif
        guard let loaded: (
            snapshotID: ByteString,
            stepID: ByteString,
            manifest: HistoricalManifest,
            step: HistoricalQueryStep
        ) = try await loadHistorical(
            continuation: continuation,
            kind: .query,
            stepType: HistoricalQueryStep.self,
            target: target,
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization
        ) else {
            return nil
        }
        return HistoricalQueryContinuation(
            readVersion: loaded.step.readVersion,
            continuation: QueryContinuation(loaded.step.continuation),
            snapshotID: loaded.snapshotID,
            stepID: loaded.stepID,
            manifest: loaded.manifest,
            step: loaded.step
        )
    }

    package func loadHistoricalGraph(
        continuation: ByteString,
        lease: DatabaseExecutionStorage,
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext
    ) async throws -> HistoricalGraphContinuation? {
        #if DATABASE_SERVER_MULTI_BASE
        let target = Target.resource(
            lease.resource,
            generation: lease.generation
        )
        #else
        let target = Target.database(generation: lease.generation)
        #endif
        guard let loaded: (
            snapshotID: ByteString,
            stepID: ByteString,
            manifest: HistoricalManifest,
            step: HistoricalGraphStep
        ) = try await loadHistorical(
            continuation: continuation,
            kind: .graph,
            stepType: HistoricalGraphStep.self,
            target: target,
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization
        ) else {
            return nil
        }
        return HistoricalGraphContinuation(
            readVersion: loaded.step.readVersion,
            resultFingerprint: loaded.step.resultFingerprint,
            offset: loaded.step.offset,
            snapshotID: loaded.snapshotID,
            stepID: loaded.stepID,
            manifest: loaded.manifest,
            step: loaded.step
        )
    }

    /// Atomically records that a historical query continuation produced its
    /// terminal response and releases the principal's active slot. The
    /// historical step remains available until expiry so replay can converge
    /// on the same terminal input without consuming an active slot.
    package func completeHistoricalQuery(
        _ current: HistoricalQueryContinuation
    ) async throws {
        try await completeHistorical(
            kind: .query,
            snapshotID: current.snapshotID,
            stepID: current.stepID,
            manifest: current.manifest
        )
    }

    /// Atomically records that a historical graph continuation produced its
    /// terminal response and releases the principal's active slot. The
    /// historical step remains available until expiry for deterministic
    /// replay.
    package func completeHistoricalGraph(
        _ current: HistoricalGraphContinuation
    ) async throws {
        try await completeHistorical(
            kind: .graph,
            snapshotID: current.snapshotID,
            stepID: current.stepID,
            manifest: current.manifest
        )
    }

    private func completeHistorical(
        kind: HistoricalKind,
        snapshotID: ByteString,
        stepID: ByteString,
        manifest expectedManifest: HistoricalManifest
    ) async throws {
        guard expectedManifest.kind == kind,
              snapshotID.count == 16,
              stepID.count == 16 else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        let terminalBytes = try DatabaseServerFrameCodec.encode(
            HistoricalTerminal(kind: kind, stepID: stepID)
        )
        guard let terminalByteCount = UInt64(exactly: terminalBytes.count) else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        try await withControlAccess { transaction in
            guard let manifestBytes = try await transaction.getValue(
                for: self.historicalManifestKey(snapshotID),
                snapshot: false
            ) else {
                throw DatabaseQueryExecutionError.invalidContinuation
            }
            let manifest: HistoricalManifest
            do {
                manifest = try DatabaseServerFrameCodec.decode(
                    HistoricalManifest.self,
                    from: manifestBytes
                )
            } catch {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            guard manifest == expectedManifest else {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            guard let stepBytes = try await transaction.getValue(
                for: self.historicalStepKey(
                    snapshotID: snapshotID,
                    stepID: stepID
                ),
                snapshot: false
            ) else {
                throw DatabaseQueryExecutionError.invalidContinuation
            }
            switch kind {
            case .query:
                do {
                    let step = try DatabaseServerFrameCodec.decode(
                        HistoricalQueryStep.self,
                        from: stepBytes
                    )
                    guard step.successorID == nil else {
                        throw DatabaseQueryExecutionError
                            .querySnapshotCorrupted
                    }
                } catch let error as DatabaseQueryExecutionError {
                    throw error
                } catch {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
            case .graph:
                do {
                    let step = try DatabaseServerFrameCodec.decode(
                        HistoricalGraphStep.self,
                        from: stepBytes
                    )
                    guard step.successorID == nil else {
                        throw DatabaseQueryExecutionError
                            .querySnapshotCorrupted
                    }
                } catch let error as DatabaseQueryExecutionError {
                    throw error
                } catch {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
            }
            if let terminalBytes = try await transaction.getValue(
                for: self.historicalTerminalKey(snapshotID),
                snapshot: false
            ) {
                let terminal: HistoricalTerminal
                do {
                    terminal = try DatabaseServerFrameCodec.decode(
                        HistoricalTerminal.self,
                        from: terminalBytes
                    )
                } catch {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                guard terminal.kind == kind,
                      terminal.stepID == stepID else {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                return
            }
            guard let usageBytes = try await transaction.getValue(
                for: self.historicalUsageKey(snapshotID),
                snapshot: false
            ) else {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            let usage: HistoricalUsage
            do {
                usage = try DatabaseServerFrameCodec.decode(
                    HistoricalUsage.self,
                    from: usageBytes
                )
            } catch {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            guard usage.storedStepBytes <= self.historicalStorageByteLimit else {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            let nextUsage = usage.storedStepBytes
                .addingReportingOverflow(terminalByteCount)
            guard !nextUsage.overflow,
                  nextUsage.partialValue <= self.historicalStorageByteLimit else {
                throw DatabaseQueryExecutionError
                    .querySnapshotStorageLimitExceeded(
                        maximumBytes: self.historicalStorageByteLimit
                    )
            }
            try transaction.setValue(
                terminalBytes,
                for: self.historicalTerminalKey(snapshotID)
            )
            try transaction.setValue(
                DatabaseServerFrameCodec.encode(
                    HistoricalUsage(storedStepBytes: nextUsage.partialValue)
                ),
                for: self.historicalUsageKey(snapshotID)
            )
            try await self.clearActiveSlotIfOwned(
                snapshotID: snapshotID,
                principalDigest: manifest.principalDigest,
                slot: manifest.slot,
                transaction: transaction
            )
        }
    }

    private func loadHistorical<Step: DatabaseServerFrameValue>(
        continuation: ByteString,
        kind: HistoricalKind,
        stepType: Step.Type,
        target: Target,
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext
    ) async throws -> (
        snapshotID: ByteString,
        stepID: ByteString,
        manifest: HistoricalManifest,
        step: Step
    )? {
        guard continuation.count == Self.continuationByteCount,
              continuation.first == Self.continuationMarker,
              queryFingerprint.count == DatabaseRequestDigest.byteCount else {
            throw DatabaseQueryExecutionError.invalidContinuation
        }
        let snapshotID = continuation[1..<17]
        let stepID = continuation[17..<33]
        let loaded: (HistoricalManifest, Step)? = try await container
            .withControlMetadataTransaction(configuration: .readOnly) {
                transaction in
                guard let manifestBytes = try await transaction
                    .executionStorageAccess.getValue(
                        for: self.historicalManifestKey(snapshotID),
                        snapshot: false
                    ) else {
                    return nil
                }
                guard let stepBytes = try await transaction
                    .executionStorageAccess.getValue(
                        for: self.historicalStepKey(
                            snapshotID: snapshotID,
                            stepID: stepID
                        ),
                        snapshot: false
                    ),
                      let usageBytes = try await transaction
                        .executionStorageAccess.getValue(
                            for: self.historicalUsageKey(snapshotID),
                            snapshot: false
                        ) else {
                    throw DatabaseQueryExecutionError.invalidContinuation
                }
                do {
                    let manifest = try DatabaseServerFrameCodec.decode(
                            HistoricalManifest.self,
                            from: manifestBytes
                        )
                    let step = try DatabaseServerFrameCodec.decode(
                        stepType,
                        from: stepBytes
                    )
                    let usage = try DatabaseServerFrameCodec.decode(
                        HistoricalUsage.self,
                        from: usageBytes
                    )
                    guard usage.storedStepBytes
                        <= self.historicalStorageByteLimit else {
                        throw DatabaseQueryExecutionError
                            .querySnapshotCorrupted
                    }
                    return (manifest, step)
                } catch {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
            }
        guard let loaded else { return nil }
        let principalDigest = try authorizationDigest(authorization)
        guard loaded.0.kind == kind,
              Self.constantTimeEqual(
                loaded.0.principalDigest,
                principalDigest
              ),
              loaded.0.target.hasSameIdentity(as: target),
              Self.constantTimeEqual(
                loaded.0.queryFingerprint,
                queryFingerprint
              ) else {
            throw DatabaseQueryExecutionError.invalidContinuation
        }
        guard loaded.0.target == target,
              loaded.0.schemaGeneration == schemaGeneration else {
            throw DatabaseQueryExecutionError.querySnapshotStale
        }
        if loaded.0.expiresAt <= clock.now {
            try await clearReserved(
                snapshotID: snapshotID,
                principalDigest: loaded.0.principalDigest,
                slot: loaded.0.slot,
                expiresAt: loaded.0.expiresAt
            )
            throw DatabaseQueryExecutionError.querySnapshotExpired
        }
        return (snapshotID, stepID, loaded.0, loaded.1)
    }

    private func advancedHistoricalUsage(
        _ usage: HistoricalUsage,
        replacing currentStepBytes: ByteString,
        with updatedStepBytes: ByteString,
        adding successorStepBytes: ByteString
    ) throws -> HistoricalUsage {
        guard let currentByteCount = UInt64(
            exactly: currentStepBytes.count
        ),
              let updatedByteCount = UInt64(
                exactly: updatedStepBytes.count
              ),
              let successorByteCount = UInt64(
                exactly: successorStepBytes.count
              ),
              usage.storedStepBytes >= currentByteCount else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        let retainedByteCount = usage.storedStepBytes - currentByteCount
        let updatedTotal = retainedByteCount.addingReportingOverflow(
            updatedByteCount
        )
        let nextTotal = updatedTotal.partialValue.addingReportingOverflow(
            successorByteCount
        )
        guard !updatedTotal.overflow,
              !nextTotal.overflow,
              nextTotal.partialValue <= historicalStorageByteLimit else {
            throw DatabaseQueryExecutionError
                .querySnapshotStorageLimitExceeded(
                    maximumBytes: historicalStorageByteLimit
                )
        }
        return HistoricalUsage(storedStepBytes: nextTotal.partialValue)
    }

    package func advanceHistoricalQuery(
        _ current: HistoricalQueryContinuation,
        to continuation: QueryContinuation
    ) async throws -> ByteString {
        guard canPersistHistoricalContinuation(continuation) else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        guard current.manifest.expiresAt > clock.now else {
            throw DatabaseQueryExecutionError.querySnapshotExpired
        }
        for _ in 0..<16 {
            let proposedID = Self.identifierBytes(
                identifierGenerator.generate()
            )
            let successorID: ByteString? = try await withControlAccess {
                transaction in
                guard let manifestBytes = try await transaction.getValue(
                    for: self.historicalManifestKey(current.snapshotID),
                    snapshot: false
                ),
                      let stepBytes = try await transaction.getValue(
                        for: self.historicalStepKey(
                            snapshotID: current.snapshotID,
                            stepID: current.stepID
                        ),
                        snapshot: false
                      ),
                      let usageBytes = try await transaction.getValue(
                        for: self.historicalUsageKey(current.snapshotID),
                        snapshot: false
                      ) else {
                    throw DatabaseQueryExecutionError.invalidContinuation
                }
                let manifest: HistoricalManifest
                let stored: HistoricalQueryStep
                let usage: HistoricalUsage
                do {
                    manifest = try DatabaseServerFrameCodec.decode(
                        HistoricalManifest.self,
                        from: manifestBytes
                    )
                    stored = try DatabaseServerFrameCodec.decode(
                        HistoricalQueryStep.self,
                        from: stepBytes
                    )
                    usage = try DatabaseServerFrameCodec.decode(
                        HistoricalUsage.self,
                        from: usageBytes
                    )
                } catch {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                guard manifest == current.manifest,
                      stored.describesSameStep(as: current.step) else {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                if let terminalBytes = try await transaction.getValue(
                    for: self.historicalTerminalKey(current.snapshotID),
                    snapshot: false
                ) {
                    let terminal: HistoricalTerminal
                    do {
                        terminal = try DatabaseServerFrameCodec.decode(
                            HistoricalTerminal.self,
                            from: terminalBytes
                        )
                    } catch {
                        throw DatabaseQueryExecutionError
                            .querySnapshotCorrupted
                    }
                    guard terminal.kind != .query
                            || terminal.stepID != current.stepID else {
                        throw DatabaseQueryExecutionError
                            .querySnapshotCorrupted
                    }
                }
                if let successorID = stored.successorID {
                    guard let successorBytes = try await transaction.getValue(
                        for: self.historicalStepKey(
                            snapshotID: current.snapshotID,
                            stepID: successorID
                        ),
                        snapshot: false
                    ) else {
                        throw DatabaseQueryExecutionError
                            .querySnapshotCorrupted
                    }
                    let successor = try DatabaseServerFrameCodec.decode(
                        HistoricalQueryStep.self,
                        from: successorBytes
                    )
                    guard successor.readVersion == current.readVersion,
                          successor.continuation == continuation.bytes else {
                        throw DatabaseQueryExecutionError
                            .querySnapshotCorrupted
                    }
                    return successorID
                }
                guard try await transaction.getValue(
                    for: self.historicalStepKey(
                        snapshotID: current.snapshotID,
                        stepID: proposedID
                    ),
                    snapshot: false
                ) == nil else {
                    return nil
                }
                let successorBytes = try DatabaseServerFrameCodec.encode(
                    HistoricalQueryStep(
                        readVersion: current.readVersion,
                        continuation: continuation.bytes
                    )
                )
                let updatedCurrentBytes = try DatabaseServerFrameCodec.encode(
                    HistoricalQueryStep(
                        readVersion: stored.readVersion,
                        continuation: stored.continuation,
                        successorID: proposedID
                    )
                )
                let nextUsage = try self.advancedHistoricalUsage(
                    usage,
                    replacing: stepBytes,
                    with: updatedCurrentBytes,
                    adding: successorBytes
                )
                try transaction.setValue(
                    successorBytes,
                    for: self.historicalStepKey(
                        snapshotID: current.snapshotID,
                        stepID: proposedID
                    )
                )
                try transaction.setValue(
                    updatedCurrentBytes,
                    for: self.historicalStepKey(
                        snapshotID: current.snapshotID,
                        stepID: current.stepID
                    )
                )
                try transaction.setValue(
                    DatabaseServerFrameCodec.encode(nextUsage),
                    for: self.historicalUsageKey(current.snapshotID)
                )
                return proposedID
            }
            if let successorID {
                return continuationToken(
                    snapshotID: current.snapshotID,
                    stepID: successorID
                )
            }
        }
        throw DatabaseQueryExecutionError.querySnapshotUnavailable(
            "unable to reserve a unique historical continuation identifier"
        )
    }

    package func advanceHistoricalGraph(
        _ current: HistoricalGraphContinuation,
        toOffset offset: UInt64
    ) async throws -> ByteString {
        guard offset > current.offset else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        guard current.manifest.expiresAt > clock.now else {
            throw DatabaseQueryExecutionError.querySnapshotExpired
        }
        for _ in 0..<16 {
            let proposedID = Self.identifierBytes(
                identifierGenerator.generate()
            )
            let successorID: ByteString? = try await withControlAccess {
                transaction in
                guard let manifestBytes = try await transaction.getValue(
                    for: self.historicalManifestKey(current.snapshotID),
                    snapshot: false
                ),
                      let stepBytes = try await transaction.getValue(
                        for: self.historicalStepKey(
                            snapshotID: current.snapshotID,
                            stepID: current.stepID
                        ),
                        snapshot: false
                      ),
                      let usageBytes = try await transaction.getValue(
                        for: self.historicalUsageKey(current.snapshotID),
                        snapshot: false
                      ) else {
                    throw DatabaseQueryExecutionError.invalidContinuation
                }
                let manifest: HistoricalManifest
                let stored: HistoricalGraphStep
                let usage: HistoricalUsage
                do {
                    manifest = try DatabaseServerFrameCodec.decode(
                        HistoricalManifest.self,
                        from: manifestBytes
                    )
                    stored = try DatabaseServerFrameCodec.decode(
                        HistoricalGraphStep.self,
                        from: stepBytes
                    )
                    usage = try DatabaseServerFrameCodec.decode(
                        HistoricalUsage.self,
                        from: usageBytes
                    )
                } catch {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                guard manifest == current.manifest,
                      stored.describesSameStep(as: current.step) else {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                if let terminalBytes = try await transaction.getValue(
                    for: self.historicalTerminalKey(current.snapshotID),
                    snapshot: false
                ) {
                    let terminal: HistoricalTerminal
                    do {
                        terminal = try DatabaseServerFrameCodec.decode(
                            HistoricalTerminal.self,
                            from: terminalBytes
                        )
                    } catch {
                        throw DatabaseQueryExecutionError
                            .querySnapshotCorrupted
                    }
                    guard terminal.kind != .graph
                            || terminal.stepID != current.stepID else {
                        throw DatabaseQueryExecutionError
                            .querySnapshotCorrupted
                    }
                }
                if let successorID = stored.successorID {
                    guard let successorBytes = try await transaction.getValue(
                        for: self.historicalStepKey(
                            snapshotID: current.snapshotID,
                            stepID: successorID
                        ),
                        snapshot: false
                    ) else {
                        throw DatabaseQueryExecutionError
                            .querySnapshotCorrupted
                    }
                    let successor = try DatabaseServerFrameCodec.decode(
                        HistoricalGraphStep.self,
                        from: successorBytes
                    )
                    guard successor.readVersion == current.readVersion,
                          successor.resultFingerprint
                            == current.resultFingerprint,
                          successor.offset == offset else {
                        throw DatabaseQueryExecutionError
                            .querySnapshotCorrupted
                    }
                    return successorID
                }
                guard try await transaction.getValue(
                    for: self.historicalStepKey(
                        snapshotID: current.snapshotID,
                        stepID: proposedID
                    ),
                    snapshot: false
                ) == nil else {
                    return nil
                }
                let successorBytes = try DatabaseServerFrameCodec.encode(
                    HistoricalGraphStep(
                        readVersion: current.readVersion,
                        resultFingerprint: current.resultFingerprint,
                        offset: offset
                    )
                )
                let updatedCurrentBytes = try DatabaseServerFrameCodec.encode(
                    HistoricalGraphStep(
                        readVersion: stored.readVersion,
                        resultFingerprint: stored.resultFingerprint,
                        offset: stored.offset,
                        successorID: proposedID
                    )
                )
                let nextUsage = try self.advancedHistoricalUsage(
                    usage,
                    replacing: stepBytes,
                    with: updatedCurrentBytes,
                    adding: successorBytes
                )
                try transaction.setValue(
                    successorBytes,
                    for: self.historicalStepKey(
                        snapshotID: current.snapshotID,
                        stepID: proposedID
                    )
                )
                try transaction.setValue(
                    updatedCurrentBytes,
                    for: self.historicalStepKey(
                        snapshotID: current.snapshotID,
                        stepID: current.stepID
                    )
                )
                try transaction.setValue(
                    DatabaseServerFrameCodec.encode(nextUsage),
                    for: self.historicalUsageKey(current.snapshotID)
                )
                return proposedID
            }
            if let successorID {
                return continuationToken(
                    snapshotID: current.snapshotID,
                    stepID: successorID
                )
            }
        }
        throw DatabaseQueryExecutionError.querySnapshotUnavailable(
            "unable to reserve a unique historical continuation identifier"
        )
    }

    package func reservePage(
        in reservation: WriteReservation
    ) async throws -> ByteString {
        for _ in 0..<16 {
            let pageID = Self.identifierBytes(identifierGenerator.generate())
            let didReserve = try await withControlAccess { transaction in
                    guard try await self.validatePending(
                        reservation,
                        transaction: transaction
                    ) else {
                        throw DatabaseQueryExecutionError
                            .querySnapshotCorrupted
                    }
                    let reservationKey = self.pageReservationKey(
                        snapshotID: reservation.snapshotID,
                        pageID: pageID
                    )
                    guard try await transaction.getValue(
                        for: reservationKey,
                        snapshot: false
                    ) == nil,
                          try await transaction.getValue(
                            for: self.pageDescriptorKey(
                                snapshotID: reservation.snapshotID,
                                pageID: pageID
                            ),
                            snapshot: false
                          ) == nil else {
                        return false
                    }
                    try transaction.setValue(
                        DatabaseServerFrameCodec.encode(PageReservation()),
                        for: reservationKey
                    )
                    return true
            }
            if didReserve { return pageID }
        }
        throw DatabaseQueryExecutionError.querySnapshotUnavailable(
            "unable to reserve a unique opaque page identifier"
        )
    }

    package func appendPage(
        _ page: QueryRowPage,
        pageID: ByteString,
        to reservation: WriteReservation,
        consumedPayloadBytes: UInt64,
        maximumIntermediateBytes: UInt64,
        workMeter: DatabaseWorkMeter
    ) async throws -> UInt64 {
        try await appendResponse(
            .rows(page),
            pageID: pageID,
            to: reservation,
            consumedPayloadBytes: consumedPayloadBytes,
            maximumIntermediateBytes: maximumIntermediateBytes,
            workMeter: workMeter
        )
    }

    package func appendPage(
        _ page: RDFGraphPage,
        pageID: ByteString,
        to reservation: WriteReservation,
        consumedPayloadBytes: UInt64,
        maximumIntermediateBytes: UInt64,
        workMeter: DatabaseWorkMeter
    ) async throws -> UInt64 {
        try await appendResponse(
            .rdfGraph(page),
            pageID: pageID,
            to: reservation,
            consumedPayloadBytes: consumedPayloadBytes,
            maximumIntermediateBytes: maximumIntermediateBytes,
            workMeter: workMeter
        )
    }

    private func appendResponse(
        _ response: QueryExecuteOperation.Response,
        pageID: ByteString,
        to reservation: WriteReservation,
        consumedPayloadBytes: UInt64,
        maximumIntermediateBytes: UInt64,
        workMeter: DatabaseWorkMeter
    ) async throws -> UInt64 {
        guard pageID.count == 16 else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        let encoder = DatabaseWireEncoder(limits: wireLimits)
        let payloadByteCount = try encoder.responsePayloadByteCount(
            DatabaseOperationCatalog.queryExecute,
            response: response
        )
        guard let encodedPayloadByteCount = UInt64(
            exactly: payloadByteCount
        ) else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        let nextTotal = consumedPayloadBytes.addingReportingOverflow(
            encodedPayloadByteCount
        )
        guard !nextTotal.overflow,
              nextTotal.partialValue <= Self.maximumSpoolBytes else {
            throw DatabaseWorkLimitError.maximumIntermediateBytes(
                stage: .resultMaterialization,
                consumed: consumedPayloadBytes,
                requested: encodedPayloadByteCount,
                maximum: Self.maximumSpoolBytes
            )
        }
        guard encodedPayloadByteCount <= maximumIntermediateBytes else {
            throw DatabaseWorkLimitError.maximumIntermediateBytes(
                stage: .resultMaterialization,
                consumed: 0,
                requested: encodedPayloadByteCount,
                maximum: maximumIntermediateBytes
            )
        }
        let payloadReservation = try workMeter.reserveIntermediate(
            bytes: encodedPayloadByteCount,
            at: .resultMaterialization
        )
        let payload = try ByteString.copying(count: payloadByteCount) {
            output in
            try encoder.encodeResponsePayload(
                DatabaseOperationCatalog.queryExecute,
                response: response,
                into: output
            )
        }

        // This is the required durability copy boundary: continuation page
        // bytes must outlive the request and survive process restart. Chunk
        // slices retain the one encoded payload owner until each authoritative
        // control-domain transaction commits.
        try await writePage(
            payload,
            reservation: reservation,
            pageID: pageID
        )
        withExtendedLifetime(payloadReservation) {}
        return nextTotal.partialValue
    }

    package func commitWrite(
        _ reservation: WriteReservation,
        pageCount: UInt32,
        totalPayloadBytes: UInt64
    ) async throws {
        guard pageCount > 0, totalPayloadBytes > 0 else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        try await publish(
            snapshotID: reservation.snapshotID,
            pending: PendingSnapshot(
                principalDigest: reservation.principalDigest,
                slot: reservation.slot,
                expiresAt: reservation.expiresAt
            ),
            target: reservation.target,
            schemaGeneration: reservation.schemaGeneration,
            principalDigest: reservation.principalDigest,
            queryFingerprint: reservation.queryFingerprint,
            expiresAt: reservation.expiresAt,
            pageCount: pageCount,
            totalPayloadBytes: totalPayloadBytes
        )
    }

    package func abortWrite(
        _ reservation: WriteReservation
    ) async throws {
        // Cancellation must not cancel cleanup itself. If the process crashes,
        // the reservation and expiry index let startup or the durable scheduler
        // finish the same idempotent cleanup.
        try await Task.detached {
            try await self.clearReserved(
                snapshotID: reservation.snapshotID,
                principalDigest: reservation.principalDigest,
                slot: reservation.slot,
                expiresAt: reservation.expiresAt
            )
        }.value
    }

    package func distinctWorkspace(
        in reservation: WriteReservation
    ) -> Subspace {
        snapshotSubspace(reservation.snapshotID).subspace("distinct")
    }

    /// Removes every expired snapshot in bounded transactions, then arms the
    /// host scheduler for the earliest remaining expiry.
    func cleanupExpired() async throws {
        while true {
            let outcome = try await container.withControlMetadataTransaction {
                transaction in
                let range = self.expirations.range()
                let entries = try await TransactionRangeCollection.collect(
                    using: transaction.executionStorageAccess,
                    from: .firstGreaterOrEqual(range.begin),
                    to: .firstGreaterOrEqual(range.end),
                    limit: 129,
                    reverse: false,
                    snapshot: false,
                    streamingMode: .iterator
                )
                var removed = 0
                var nextExpiry: Timestamp?
                for (key, bytes) in entries {
                    let record: ExpiryRecord
                    do {
                        record = try DatabaseServerFrameCodec.decode(
                            ExpiryRecord.self,
                            from: bytes
                        )
                    } catch {
                        throw DatabaseQueryExecutionError
                            .querySnapshotCorrupted
                    }
                    guard record.expiresAt <= self.clock.now else {
                        nextExpiry = record.expiresAt
                        break
                    }
                    guard removed < 128 else { break }
                    try self.clearSnapshot(
                        record.snapshotID,
                        transaction: transaction.executionStorageAccess
                    )
                    let slotKey = self.principalSlotKey(
                        principalDigest: record.principalDigest,
                        slot: record.slot
                    )
                    if let slotBytes = try await transaction.executionStorageAccess
                        .getValue(for: slotKey, snapshot: false) {
                        let slot = try DatabaseServerFrameCodec.decode(
                            PrincipalSlot.self,
                            from: slotBytes
                        )
                        if slot.snapshotID == record.snapshotID {
                            try transaction.executionStorageAccess.clear(key: slotKey)
                        }
                    }
                    try transaction.executionStorageAccess.clear(key: key)
                    removed += 1
                }
                return (removed: removed, nextExpiry: nextExpiry)
            }
            if outcome.removed == 128 {
                continue
            }
            if let nextExpiry = outcome.nextExpiry {
                try await scheduler.ensureWakeUp(noLaterThan: nextExpiry)
            }
            return
        }
    }

    #if DATABASE_SERVER_MULTI_BASE
    func load(
        continuation: ByteString,
        resource: Security.Resource,
        dataGeneration: UInt64,
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext
    ) async throws -> QueryRowPage {
        let response = try await loadResponse(
            continuation: continuation,
            target: .resource(resource, generation: dataGeneration),
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization,
            compositionBaseIDs: nil
        )
        guard case .rows(let page) = response,
              page.provenance == nil else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        return page
    }

    func loadRDFGraph(
        continuation: ByteString,
        resource: Security.Resource,
        dataGeneration: UInt64,
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext
    ) async throws -> RDFGraphPage {
        let response = try await loadResponse(
            continuation: continuation,
            target: .resource(resource, generation: dataGeneration),
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization,
            compositionBaseIDs: nil
        )
        guard case .rdfGraph(let page) = response,
              page.provenance == nil else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        return page
    }
    #else
    func load(
        continuation: ByteString,
        dataGeneration: UInt64,
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext
    ) async throws -> QueryRowPage {
        let response = try await loadResponse(
            continuation: continuation,
            target: .database(generation: dataGeneration),
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization,
            compositionBaseIDs: nil
        )
        guard case .rows(let page) = response else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        return page
    }

    func loadRDFGraph(
        continuation: ByteString,
        dataGeneration: UInt64,
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext
    ) async throws -> RDFGraphPage {
        let response = try await loadResponse(
            continuation: continuation,
            target: .database(generation: dataGeneration),
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization,
            compositionBaseIDs: nil
        )
        guard case .rdfGraph(let page) = response else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        return page
    }
    #endif

    #if DATABASE_SERVER_MULTI_BASE
    func load(
        continuation: ByteString,
        composition: CompositionResolution,
        basePlacementGenerations: [Base.ID: UInt64],
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext
    ) async throws -> QueryRowPage {
        let response = try await loadResponse(
            continuation: continuation,
            target: .composition(
                composition,
                basePlacementGenerations: basePlacementGenerations
            ),
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization,
            compositionBaseIDs: composition.bases
        )
        guard case .rows(let page) = response else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        return page
    }

    func loadRDFGraph(
        continuation: ByteString,
        composition: CompositionResolution,
        basePlacementGenerations: [Base.ID: UInt64],
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext
    ) async throws -> RDFGraphPage {
        let response = try await loadResponse(
            continuation: continuation,
            target: .composition(
                composition,
                basePlacementGenerations: basePlacementGenerations
            ),
            schemaGeneration: schemaGeneration,
            queryFingerprint: queryFingerprint,
            authorization: authorization,
            compositionBaseIDs: composition.bases
        )
        guard case .rdfGraph(let page) = response else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        return page
    }
    #endif

    private func loadResponse(
        continuation: ByteString,
        target: Target,
        schemaGeneration: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext,
        compositionBaseIDs: DatabaseSnapshotCompositionMembers?
    ) async throws -> QueryExecuteOperation.Response {
        guard continuation.count == Self.continuationByteCount,
              continuation.first == Self.continuationMarker,
              queryFingerprint.count == 32,
              authorization.principal != nil else {
            throw DatabaseQueryExecutionError.invalidContinuation
        }
        let snapshotID = continuation[1..<17]
        let pageID = continuation[17..<33]
        let principalDigest = try authorizationDigest(authorization)
        let now = clock.now

        let loaded: (Manifest, ByteString)
        do {
            loaded = try await container.withControlMetadataTransaction(
                configuration: .readOnly
            ) { transaction in
                guard let manifestBytes = try await transaction.executionStorageAccess
                    .getValue(
                        for: self.manifestKey(snapshotID),
                        snapshot: false
                    ) else {
                    throw DatabaseQueryExecutionError.invalidContinuation
                }
                let manifest = try DatabaseServerFrameCodec.decode(
                    Manifest.self,
                    from: manifestBytes
                )
                guard let descriptorBytes = try await transaction.executionStorageAccess
                    .getValue(
                        for: self.pageDescriptorKey(
                            snapshotID: snapshotID,
                            pageID: pageID
                        ),
                        snapshot: false
                    ) else {
                    throw DatabaseQueryExecutionError
                        .querySnapshotCorrupted
                }
                let descriptor = try DatabaseServerFrameCodec.decode(
                    PageDescriptor.self,
                    from: descriptorBytes
                )
                guard let payloadByteCount = Int(
                    exactly: descriptor.payloadByteCount
                ),
                      let chunkCount = Int(exactly: descriptor.chunkCount)
                else {
                    throw DatabaseQueryExecutionError
                        .querySnapshotCorrupted
                }
                var chunks: [ByteString] = []
                chunks.reserveCapacity(chunkCount)
                var actualByteCount = 0
                for chunkIndex in 0..<chunkCount {
                    guard let chunk = try await transaction.executionStorageAccess
                        .getValue(
                            for: self.pageChunkKey(
                                snapshotID: snapshotID,
                                pageID: pageID,
                                chunkIndex: chunkIndex
                            ),
                            snapshot: false
                        ) else {
                        throw DatabaseQueryExecutionError
                            .querySnapshotCorrupted
                    }
                    let next = actualByteCount.addingReportingOverflow(
                        chunk.count
                    )
                    guard !next.overflow,
                          next.partialValue <= payloadByteCount else {
                        throw DatabaseQueryExecutionError
                            .querySnapshotCorrupted
                    }
                    actualByteCount = next.partialValue
                    chunks.append(chunk)
                }
                guard actualByteCount == payloadByteCount else {
                    throw DatabaseQueryExecutionError
                        .querySnapshotCorrupted
                }
                // Persisted pages are split into backend-sized chunks, while
                // DatabaseWireDecoder requires one contiguous retained owner.
                // This is the single required reassembly copy at the durable
                // snapshot boundary; both the chunks and destination are
                // bounded by `maximumSpoolBytes` (16 MiB).
                let payload = ByteString.copying(count: payloadByteCount) {
                    destination in
                    var offset = 0
                    for chunk in chunks {
                        chunk.withUnsafeBytes { source in
                            UnsafeMutableRawBufferPointer(
                                rebasing: destination[
                                    offset..<(offset + source.count)
                                ]
                            ).copyMemory(from: source)
                            offset += source.count
                        }
                    }
                }
                guard Self.constantTimeEqual(
                    Self.digest(payload),
                    descriptor.digest
                ) else {
                    throw DatabaseQueryExecutionError
                        .querySnapshotCorrupted
                }
                return (manifest, payload)
            }
        } catch let error as DatabaseQueryExecutionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }

        let manifest = loaded.0
        guard Self.constantTimeEqual(
            manifest.principalDigest,
            principalDigest
        ) else {
            throw DatabaseQueryExecutionError.invalidContinuation
        }
        guard manifest.target.hasSameIdentity(as: target),
              Self.constantTimeEqual(
                manifest.queryFingerprint,
                queryFingerprint
              ) else {
            throw DatabaseQueryExecutionError.invalidContinuation
        }
        guard manifest.target == target,
              manifest.schemaGeneration == schemaGeneration else {
            throw DatabaseQueryExecutionError.querySnapshotStale
        }
        if manifest.expiresAt <= now {
            try await Task.detached {
                try await self.clearReserved(
                    snapshotID: snapshotID,
                    principalDigest: manifest.principalDigest,
                    slot: manifest.slot,
                    expiresAt: manifest.expiresAt
                )
            }.value
            throw DatabaseQueryExecutionError.querySnapshotExpired
        }
        let response: QueryExecuteOperation.Response
        do {
            response = try DatabaseWireDecoder(limits: wireLimits)
                .decodeResponsePayload(
                    DatabaseOperationCatalog.queryExecute,
                    from: loaded.1
                )
        } catch {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        let next: ByteString?
        #if DATABASE_SERVER_MULTI_BASE
        let provenance: CompositionPageProvenance?
        switch response {
        case .rows(let page):
            provenance = page.provenance
            next = page.continuation
        case .rdfGraph(let page):
            provenance = page.provenance
            next = page.continuation
        case .boolean:
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        switch target {
        case .resource:
            guard provenance == nil else {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
        case .composition(let composition, _):
            guard let provenance,
                  provenance.composition == composition,
                  provenance.baseIDs == compositionBaseIDs else {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
        }
        #else
        _ = compositionBaseIDs
        switch response {
        case .rows(let page):
            next = page.continuation
        case .rdfGraph(let page):
            next = page.continuation
        case .boolean:
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        guard case .database = target else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        #endif
        if let next {
            guard next.count == Self.continuationByteCount,
                  next.first == Self.continuationMarker,
                  next[1..<17] == snapshotID else {
                throw DatabaseQueryExecutionError
                    .querySnapshotCorrupted
            }
        } else {
            try await terminalizePage(
                snapshotID: snapshotID,
                pageID: pageID,
                manifest: manifest
            )
        }
        return response
    }

    private func terminalizePage(
        snapshotID: ByteString,
        pageID: ByteString,
        manifest expectedManifest: Manifest
    ) async throws {
        guard snapshotID.count == 16, pageID.count == 16 else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        try await withControlAccess { transaction in
            guard let manifestBytes = try await transaction.getValue(
                for: self.manifestKey(snapshotID),
                snapshot: false
            ) else {
                throw DatabaseQueryExecutionError.invalidContinuation
            }
            let manifest: Manifest
            do {
                manifest = try DatabaseServerFrameCodec.decode(
                    Manifest.self,
                    from: manifestBytes
                )
            } catch {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            guard manifest == expectedManifest else {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            if let terminalBytes = try await transaction.getValue(
                for: self.terminalKey(snapshotID),
                snapshot: false
            ) {
                let terminal: TerminalRecord
                do {
                    terminal = try DatabaseServerFrameCodec.decode(
                        TerminalRecord.self,
                        from: terminalBytes
                    )
                } catch {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                guard terminal.pageID == pageID else {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                return
            }
            try transaction.setValue(
                DatabaseServerFrameCodec.encode(TerminalRecord(pageID: pageID)),
                for: self.terminalKey(snapshotID)
            )
            try await self.clearActiveSlotIfOwned(
                snapshotID: snapshotID,
                principalDigest: manifest.principalDigest,
                slot: manifest.slot,
                transaction: transaction
            )
        }
    }

    static func queryFingerprint(
        query: SelectQuery,
        request: QueryExecuteOperation.Request,
        limits: DatabaseWireLimits
    ) throws -> ByteString {
        try queryFingerprint(
            statement: .select(query),
            request: request,
            limits: limits
        )
    }

    static func queryFingerprint(
        statement: QueryStatement,
        request: QueryExecuteOperation.Request,
        limits: DatabaseWireLimits
    ) throws -> ByteString {
        let normalized = QueryExecuteOperation.Request(
            input: .ir(statement),
            parameters: [],
            graphPartitions: request.graphPartitions,
            page: QueryExecuteOperation.Page(limit: request.page.limit),
            budget: request.budget
        )
        return digest(
            try DatabaseWireEncoder(limits: limits).encodeRequestPayload(
                DatabaseOperationCatalog.queryExecute,
                request: normalized
            )
        )
    }

    private func writePage(
        _ payload: ByteString,
        reservation: WriteReservation,
        pageID: ByteString
    ) async throws {
        let snapshotID = reservation.snapshotID
        let chunkCount = (payload.count - 1) / Self.chunkByteCount + 1
        guard let encodedChunkCount = UInt32(exactly: chunkCount) else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        for chunkIndex in 0..<chunkCount {
            let start = chunkIndex * Self.chunkByteCount
            let end = min(start + Self.chunkByteCount, payload.count)
            let chunk = payload[start..<end]
            try await withControlAccess {
                transaction in
                try transaction.setValue(
                    chunk,
                    for: self.pageChunkKey(
                        snapshotID: snapshotID,
                        pageID: pageID,
                        chunkIndex: chunkIndex
                    )
                )
            }
        }
        let descriptor = PageDescriptor(
            chunkCount: encodedChunkCount,
            payloadByteCount: UInt64(payload.count),
            digest: Self.digest(payload)
        )
        try await withControlAccess { transaction in
            guard try await self.validatePending(
                reservation,
                transaction: transaction
            ),
                  let pageReservationBytes = try await transaction
                    .getValue(
                        for: self.pageReservationKey(
                            snapshotID: snapshotID,
                            pageID: pageID
                        ),
                        snapshot: false
                    ) else {
                throw DatabaseQueryExecutionError
                    .querySnapshotCorrupted
            }
            do {
                _ = try DatabaseServerFrameCodec.decode(
                    PageReservation.self,
                    from: pageReservationBytes
                )
            } catch {
                throw DatabaseQueryExecutionError
                    .querySnapshotCorrupted
            }
            guard try await transaction.getValue(
                for: self.pageDescriptorKey(
                    snapshotID: snapshotID,
                    pageID: pageID
                ),
                snapshot: false
            ) == nil else {
                throw DatabaseQueryExecutionError
                    .querySnapshotCorrupted
            }
            try transaction.setValue(
                DatabaseServerFrameCodec.encode(descriptor),
                for: self.pageDescriptorKey(
                    snapshotID: snapshotID,
                    pageID: pageID
                )
            )
            try transaction.clear(
                key: self.pageReservationKey(
                    snapshotID: snapshotID,
                    pageID: pageID
                )
            )
        }
    }

    private func publish(
        snapshotID: ByteString,
        pending: PendingSnapshot,
        target: Target,
        schemaGeneration: UInt64,
        principalDigest: ByteString,
        queryFingerprint: ByteString,
        expiresAt: Timestamp,
        pageCount: UInt32,
        totalPayloadBytes: UInt64
    ) async throws {
        try await withControlAccess {
            transaction in
            try await self.validateCurrentTarget(
                target,
                transaction: transaction
            )
            guard try await transaction.getValue(
                for: self.manifestKey(snapshotID),
                snapshot: false
            ) == nil else {
                throw DatabaseQueryExecutionError
                    .querySnapshotCorrupted
            }
            guard principalDigest == pending.principalDigest,
                  expiresAt == pending.expiresAt,
                  let pendingBytes = try await transaction
                .getValue(
                    for: self.pendingKey(snapshotID),
                    snapshot: false
                ) else {
                throw DatabaseQueryExecutionError
                    .querySnapshotCorrupted
            }
            let storedPending: PendingSnapshot
            do {
                storedPending = try DatabaseServerFrameCodec.decode(
                    PendingSnapshot.self,
                    from: pendingBytes
                )
            } catch {
                throw DatabaseQueryExecutionError
                    .querySnapshotCorrupted
            }
            guard storedPending.principalDigest == pending.principalDigest,
                  storedPending.slot == pending.slot,
                  storedPending.expiresAt == pending.expiresAt,
                  let slotBytes = try await transaction
                    .getValue(
                        for: self.principalSlotKey(
                            principalDigest: pending.principalDigest,
                            slot: pending.slot
                        ),
                        snapshot: false
                    ) else {
                throw DatabaseQueryExecutionError
                    .querySnapshotCorrupted
            }
            let storedSlot: PrincipalSlot
            do {
                storedSlot = try DatabaseServerFrameCodec.decode(
                    PrincipalSlot.self,
                    from: slotBytes
                )
            } catch {
                throw DatabaseQueryExecutionError
                    .querySnapshotCorrupted
            }
            guard storedSlot.snapshotID == snapshotID,
                  storedSlot.expiresAt == expiresAt else {
                throw DatabaseQueryExecutionError
                    .querySnapshotCorrupted
            }
            let manifest = Manifest(
                target: target,
                schemaGeneration: schemaGeneration,
                principalDigest: principalDigest,
                queryFingerprint: queryFingerprint,
                expiresAt: expiresAt,
                slot: pending.slot,
                pageCount: pageCount,
                totalPayloadBytes: totalPayloadBytes
            )
            try transaction.setValue(
                DatabaseServerFrameCodec.encode(manifest),
                for: self.manifestKey(snapshotID)
            )
            try transaction.clear(
                key: self.pendingKey(snapshotID)
            )
        }
    }

    private func validateCurrentTarget(
        _ target: Target,
        transaction: any TransactionAccess
    ) async throws {
        #if DATABASE_SERVER_MULTI_BASE
        switch target {
        case .resource(.database, _):
            return
        case .resource(.base(let id), let generation):
            guard let current = try await container.executionLoadBaseRecord(
                id,
                transaction: transaction
            ), current.placementGeneration == generation,
               current.lifecycle == .active else {
                throw DatabaseQueryExecutionError.querySnapshotStale
            }
        case .composition(let composition, let baseGenerations):
            switch composition.kind {
            case .named:
                guard let id = composition.namedID,
                      let generation = composition.generation,
                      let current = try await container
                        .executionLoadCompositionRecord(
                            id,
                            transaction: transaction
                        ), current.generation == generation,
                      current.composition.bases == composition.bases else {
                    throw DatabaseQueryExecutionError.querySnapshotStale
                }
            case .derived:
                break
            }
            for id in composition.bases {
                guard let expectedGeneration = baseGenerations[id],
                      let current = try await container
                        .executionLoadBaseRecord(
                            id,
                            transaction: transaction
                        ),
                      current.placementGeneration == expectedGeneration,
                      current.lifecycle == .active else {
                    throw DatabaseQueryExecutionError.querySnapshotStale
                }
            }
        }
        #else
        _ = transaction
        guard case .database = target else {
            throw DatabaseQueryExecutionError.querySnapshotStale
        }
        #endif
    }

    private func reserve(
        snapshotID: ByteString,
        principalDigest: ByteString,
        expiresAt: Timestamp,
        now: Timestamp
    ) async throws -> PendingSnapshot? {
        try await withControlAccess { transaction in
            guard try await transaction.getValue(
                for: self.pendingKey(snapshotID),
                snapshot: false
            ) == nil,
                  try await transaction.getValue(
                    for: self.manifestKey(snapshotID),
                    snapshot: false
                  ) == nil,
                  try await transaction.getValue(
                    for: self.historicalManifestKey(snapshotID),
                    snapshot: false
                  ) == nil else { return nil }
            let selection = try await self.availableSlot(
                principalDigest: principalDigest,
                now: now,
                transaction: transaction
            )
            if let expiredSnapshotID = selection.expiredSnapshotID {
                guard let expiredAt = selection.expiredAt else {
                    throw DatabaseQueryExecutionError
                        .querySnapshotCorrupted
                }
                try self.clearSnapshot(
                    expiredSnapshotID,
                    transaction: transaction
                )
                try transaction.clear(
                    key: self.expiryKey(
                        snapshotID: expiredSnapshotID,
                        expiresAt: expiredAt
                    )
                )
            }
            let pending = PendingSnapshot(
                principalDigest: principalDigest,
                slot: selection.slot,
                expiresAt: expiresAt
            )
            try transaction.setValue(
                DatabaseServerFrameCodec.encode(pending),
                for: self.pendingKey(snapshotID)
            )
            try transaction.setValue(
                DatabaseServerFrameCodec.encode(
                    PrincipalSlot(
                        snapshotID: snapshotID,
                        expiresAt: expiresAt
                    )
                ),
                for: self.principalSlotKey(
                    principalDigest: principalDigest,
                    slot: selection.slot
                )
            )
            try transaction.setValue(
                DatabaseServerFrameCodec.encode(
                    ExpiryRecord(
                        snapshotID: snapshotID,
                        principalDigest: principalDigest,
                        slot: selection.slot,
                        expiresAt: expiresAt
                    )
                ),
                for: self.expiryKey(
                    snapshotID: snapshotID,
                    expiresAt: expiresAt
                )
            )
            return pending
        }
    }

    private func withControlAccess<Result: Sendable>(
        _ operation: @Sendable @escaping (
            any TransactionAccess
        ) async throws -> Result
    ) async throws -> Result {
        return try await container.withControlMetadataTransaction {
            transaction in
            try await operation(transaction.executionStorageAccess)
        }
    }

    private func validatePending(
        _ reservation: WriteReservation,
        transaction: any TransactionAccess
    ) async throws -> Bool {
        guard let bytes = try await transaction.getValue(
            for: pendingKey(reservation.snapshotID),
            snapshot: false
        ) else {
            return false
        }
        let stored: PendingSnapshot
        do {
            stored = try DatabaseServerFrameCodec.decode(
                PendingSnapshot.self,
                from: bytes
            )
        } catch {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        return Self.constantTimeEqual(
            stored.principalDigest,
            reservation.principalDigest
        ) && stored.slot == reservation.slot
            && stored.expiresAt == reservation.expiresAt
    }

    private func availableSlot(
        principalDigest: ByteString,
        now: Timestamp,
        transaction: any TransactionAccess
    ) async throws -> (
        slot: UInt8,
        expiredSnapshotID: ByteString?,
        expiredAt: Timestamp?
    ) {
        for slot in 0..<Self.maximumActiveCount {
            guard let bytes = try await transaction.getValue(
                for: principalSlotKey(
                    principalDigest: principalDigest,
                    slot: slot
                ),
                snapshot: false
            ) else {
                return (slot, nil, nil)
            }
            let record: PrincipalSlot
            do {
                record = try DatabaseServerFrameCodec.decode(
                    PrincipalSlot.self,
                    from: bytes
                )
            } catch {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            if record.expiresAt <= now {
                return (slot, record.snapshotID, record.expiresAt)
            }
        }
        throw DatabaseQueryExecutionError.querySnapshotLimitExceeded(
            maximum: Self.maximumActiveCount
        )
    }

    private func clearReserved(
        snapshotID: ByteString,
        principalDigest: ByteString,
        slot: UInt8,
        expiresAt: Timestamp
    ) async throws {
        try await container.withControlMetadataTransaction { transaction in
            try self.clearSnapshot(
                snapshotID,
                transaction: transaction.executionStorageAccess
            )
            try transaction.executionStorageAccess.clear(
                key: self.expiryKey(
                    snapshotID: snapshotID,
                    expiresAt: expiresAt
                )
            )
            try await self.clearActiveSlotIfOwned(
                snapshotID: snapshotID,
                principalDigest: principalDigest,
                slot: slot,
                transaction: transaction.executionStorageAccess
            )
        }
    }

    private func clearActiveSlotIfOwned(
        snapshotID: ByteString,
        principalDigest: ByteString,
        slot: UInt8,
        transaction: any TransactionAccess
    ) async throws {
        let slotKey = self.principalSlotKey(
            principalDigest: principalDigest,
            slot: slot
        )
        guard let slotBytes = try await transaction.getValue(
            for: slotKey,
            snapshot: false
        ) else {
            return
        }
        let storedSlot: PrincipalSlot
        do {
            storedSlot = try DatabaseServerFrameCodec.decode(
                PrincipalSlot.self,
                from: slotBytes
            )
        } catch {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        guard storedSlot.snapshotID == snapshotID else {
            return
        }
        try transaction.clear(key: slotKey)
    }

    private func clearSnapshot(
        _ snapshotID: ByteString,
        transaction: any TransactionAccess
    ) throws {
        let range = snapshotSubspace(snapshotID).range()
        try transaction.clearRange(
            beginKey: range.begin,
            endKey: range.end
        )
    }

    private func snapshotSubspace(_ snapshotID: ByteString) -> Subspace {
        snapshots.subspace(snapshotID)
    }

    private func manifestKey(_ snapshotID: ByteString) -> ByteString {
        snapshotSubspace(snapshotID).pack(Tuple("manifest"))
    }

    private func historicalManifestKey(
        _ snapshotID: ByteString
    ) -> ByteString {
        snapshotSubspace(snapshotID).pack(Tuple("historical-manifest"))
    }

    private func historicalStepKey(
        snapshotID: ByteString,
        stepID: ByteString
    ) -> ByteString {
        snapshotSubspace(snapshotID)
            .subspace("historical-steps")
            .pack(Tuple(stepID))
    }

    private func historicalUsageKey(
        _ snapshotID: ByteString
    ) -> ByteString {
        snapshotSubspace(snapshotID).pack(Tuple("historical-usage"))
    }

    private func historicalTerminalKey(
        _ snapshotID: ByteString
    ) -> ByteString {
        snapshotSubspace(snapshotID).pack(Tuple("historical-terminal"))
    }

    private func pendingKey(_ snapshotID: ByteString) -> ByteString {
        snapshotSubspace(snapshotID).pack(Tuple("pending"))
    }

    private func terminalKey(_ snapshotID: ByteString) -> ByteString {
        snapshotSubspace(snapshotID).pack(Tuple("terminal"))
    }

    private func pageSubspace(
        snapshotID: ByteString,
        pageID: ByteString
    ) -> Subspace {
        snapshotSubspace(snapshotID).subspace("pages").subspace(pageID)
    }

    private func pageDescriptorKey(
        snapshotID: ByteString,
        pageID: ByteString
    ) -> ByteString {
        pageSubspace(snapshotID: snapshotID, pageID: pageID)
            .pack(Tuple("descriptor"))
    }

    private func pageReservationKey(
        snapshotID: ByteString,
        pageID: ByteString
    ) -> ByteString {
        pageSubspace(snapshotID: snapshotID, pageID: pageID)
            .pack(Tuple("reservation"))
    }

    private func pageChunkKey(
        snapshotID: ByteString,
        pageID: ByteString,
        chunkIndex: Int
    ) -> ByteString {
        pageSubspace(snapshotID: snapshotID, pageID: pageID)
            .subspace("chunks")
            .pack(Tuple(UInt64(chunkIndex)))
    }

    private func principalSlotKey(
        principalDigest: ByteString,
        slot: UInt8
    ) -> ByteString {
        principalSlots.subspace(principalDigest).pack(Tuple(UInt64(slot)))
    }

    private func expiryKey(
        snapshotID: ByteString,
        expiresAt: Timestamp
    ) -> ByteString {
        expirations.pack(
            Tuple(
                expiresAt.secondsSinceUnixEpoch,
                UInt64(expiresAt.nanoseconds),
                snapshotID
            )
        )
    }

    private static func addingLifetime(
        to timestamp: Timestamp
    ) throws -> Timestamp {
        let seconds = timestamp.secondsSinceUnixEpoch.addingReportingOverflow(
            snapshotLifetimeSeconds
        )
        guard !seconds.overflow else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        return try Timestamp(
            secondsSinceUnixEpoch: seconds.partialValue,
            nanoseconds: timestamp.nanoseconds
        )
    }

    private static func identifierBytes(
        _ identifier: DatabaseTypes.UUID
    ) -> ByteString {
        ByteString.copying(count: 16) { destination in
            for offset in 0..<16 {
                destination[offset] = identifier[offset]
            }
        }
    }

    private static func digest(_ bytes: ByteString) -> ByteString {
        var accumulator = SHA256Accumulator()
        bytes.withUnsafeBytes { accumulator.update($0) }
        return accumulator.finalize()
    }

    private static func digest(utf8 string: String) -> ByteString {
        var accumulator = SHA256Accumulator()
        let usedContiguousStorage = string.utf8
            .withContiguousStorageIfAvailable { bytes -> Bool in
                accumulator.update(UnsafeRawBufferPointer(bytes))
                return true
            } ?? false
        if !usedContiguousStorage {
            for byte in string.utf8 {
                withUnsafeBytes(of: byte) { accumulator.update($0) }
            }
        }
        return accumulator.finalize()
    }

    private func authorizationDigest(
        _ authorization: AuthorizationContext
    ) throws -> ByteString {
        guard let principal = authorization.principal else {
            throw DatabaseQueryExecutionError.invalidContinuation
        }
        let encoded = try DatabaseWireWriter.encode(limits: wireLimits) {
            (writer: inout DatabaseWireWriter) throws(DatabaseWireError) in
            try writer.writeString(principal.identifier)
            let roles = principal.roles.sorted()
            try writer.writeCount(roles.count)
            for role in roles {
                try writer.writeString(role)
            }
            try principal.claims.encode(into: &writer)
        }
        return Self.digest(encoded)
    }

    private func continuationToken(
        snapshotID: ByteString,
        stepID: ByteString
    ) -> ByteString {
        ByteString([Self.continuationMarker])
            .appending(contentsOf: snapshotID)
            .appending(contentsOf: stepID)
    }

    private static func constantTimeEqual(
        _ lhs: ByteString,
        _ rhs: ByteString
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.withUnsafeBytes { left in
            rhs.withUnsafeBytes { right in
                var difference: UInt8 = 0
                for index in 0..<left.count {
                    difference |= left[index] ^ right[index]
                }
                return difference == 0
            }
        }
    }
}
