import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
#if DATABASE_SERVER_MULTIPLE_BASES
#if DATABASE_OPERATIONS_GRAPH_INDEXES
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire

/// Publishes a globally distinct Composition RDF graph while retaining only
/// the visible page in memory. GraphIndex resolves exact identity and merged
/// contributors before this server-owned result spool receives them.
actor DatabaseCompositionRDFResultBuilder {
    private struct PageBuffer: Sendable {
        var quads: [RDFQuad] = []
        var origins: [CompositionOrigin] = []
        var reservation: DatabaseIntermediateReservation?

        var count: Int { quads.count }

        mutating func append(
            quad: RDFQuad,
            origin: CompositionOrigin,
            footprint: DatabaseExecutionFootprint,
            workMeter: DatabaseWorkMeter
        ) throws {
            if let reservation {
                try reservation.reserveAdditional(
                    rows: footprint.rows,
                    bytes: footprint.bytes,
                    at: .resultMaterialization
                )
            } else {
                reservation = try workMeter.reserveIntermediate(
                    rows: footprint.rows,
                    bytes: footprint.bytes,
                    at: .resultMaterialization
                )
            }
            quads.append(quad)
            origins.append(origin)
        }

        mutating func release() {
            reservation?.release()
            reservation = nil
            quads.removeAll(keepingCapacity: false)
            origins.removeAll(keepingCapacity: false)
        }

        mutating func promoteToOutput() {
            reservation?.release()
            reservation = nil
        }
    }

    private enum State: Sendable, Equatable {
        case accumulating
        case completed
        case aborted
    }

    private let composition: CompositionResolution
    private let basePlacementGenerations: [Base.ID: UInt64]
    private let schemaGeneration: UInt64
    private let consistency: DatabaseKit.DatabaseReadConsistency
    private let pageLimit: Int
    private let maximumIntermediateBytes: UInt64
    private let queryFingerprint: ByteString
    private let authorization: AuthorizationContext
    private let snapshotStore: DatabaseQuerySnapshotStore
    private let workMeter: DatabaseWorkMeter
    private let footprintMeter: DatabaseRDFExecutionFootprintMeter

    private var state: State = .accumulating
    private var firstPageBuffer: PageBuffer?
    private var currentPageBuffer = PageBuffer()
    private var writeReservation: DatabaseQuerySnapshotStore.WriteReservation?
    private var firstContinuationPageID: ByteString?
    private var currentPageID: ByteString?
    private var continuationPageCount: UInt32 = 0
    private var totalPayloadBytes: UInt64 = 0

    init(
        composition: CompositionResolution,
        basePlacementGenerations: [Base.ID: UInt64],
        consistency: DatabaseKit.DatabaseReadConsistency,
        schemaGeneration: UInt64,
        pageLimit: Int,
        maximumIntermediateBytes: UInt64,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext,
        snapshotStore: DatabaseQuerySnapshotStore,
        workMeter: DatabaseWorkMeter
    ) throws {
        self.composition = composition
        self.basePlacementGenerations = basePlacementGenerations
        self.schemaGeneration = schemaGeneration
        self.consistency = consistency
        self.pageLimit = pageLimit
        self.maximumIntermediateBytes = maximumIntermediateBytes
        self.queryFingerprint = queryFingerprint
        self.authorization = authorization
        self.snapshotStore = snapshotStore
        self.workMeter = workMeter
        self.footprintMeter = try DatabaseRDFExecutionFootprintMeter.make(
            workMeter: workMeter,
            stage: .resultMaterialization
        )
    }

    func append(
        _ quad: RDFQuad,
        origin: CompositionOrigin
    ) async throws {
        guard state == .accumulating else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        if currentPageBuffer.count == pageLimit {
            try await makeRoomForAdditionalQuad()
        }
        let footprint = try footprintMeter.footprint(of: quad)
        try currentPageBuffer.append(
            quad: quad,
            origin: origin,
            footprint: footprint,
            workMeter: workMeter
        )
    }

    func finish() async throws -> RDFGraphPage {
        guard state == .accumulating else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        defer { footprintMeter.shutdown() }
        guard firstPageBuffer != nil else {
            let page = try makePage(currentPageBuffer, continuation: nil)
            if let writeReservation {
                try await snapshotStore.abortWrite(writeReservation)
            }
            currentPageBuffer.release()
            writeReservation = nil
            state = .completed
            return page
        }
        guard let writeReservation,
              let currentPageID,
              let firstContinuationPageID,
              let firstPageBuffer else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }

        let lastPage = try makePage(currentPageBuffer, continuation: nil)
        totalPayloadBytes = try await snapshotStore.appendPage(
            lastPage,
            pageID: currentPageID,
            to: writeReservation,
            consumedPayloadBytes: totalPayloadBytes,
            maximumIntermediateBytes: maximumIntermediateBytes
        )
        continuationPageCount = try increment(continuationPageCount)

        let firstPage = try makePage(
            firstPageBuffer,
            continuation: writeReservation.continuation(
                pageID: firstContinuationPageID
            )
        )
        try await snapshotStore.commitWrite(
            writeReservation,
            pageCount: continuationPageCount,
            totalPayloadBytes: totalPayloadBytes
        )
        currentPageBuffer.release()
        var retainedFirstPage = firstPageBuffer
        retainedFirstPage.release()
        self.firstPageBuffer = nil
        self.writeReservation = nil
        state = .completed
        return firstPage
    }

    func abort() async throws {
        guard state == .accumulating else { return }
        state = .aborted
        footprintMeter.shutdown()
        defer {
            currentPageBuffer.release()
            if var firstPageBuffer { firstPageBuffer.release() }
            self.firstPageBuffer = nil
            writeReservation = nil
        }
        if let writeReservation {
            try await snapshotStore.abortWrite(writeReservation)
        }
    }

    private func makeRoomForAdditionalQuad() async throws {
        if firstPageBuffer == nil {
            let writeReservation = try await snapshotStore.beginWrite(
                composition: composition,
                basePlacementGenerations: basePlacementGenerations,
                schemaGeneration: schemaGeneration,
                queryFingerprint: queryFingerprint,
                authorization: authorization
            )
            self.writeReservation = writeReservation
            let pageID = try await snapshotStore.reservePage(
                in: writeReservation
            )
            firstContinuationPageID = pageID
            currentPageID = pageID
            var outputPageBuffer = currentPageBuffer
            outputPageBuffer.promoteToOutput()
            firstPageBuffer = outputPageBuffer
            currentPageBuffer = PageBuffer()
            return
        }
        guard let writeReservation, let currentPageID else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        let nextPageID = try await snapshotStore.reservePage(
            in: writeReservation
        )
        let page = try makePage(
            currentPageBuffer,
            continuation: writeReservation.continuation(pageID: nextPageID)
        )
        totalPayloadBytes = try await snapshotStore.appendPage(
            page,
            pageID: currentPageID,
            to: writeReservation,
            consumedPayloadBytes: totalPayloadBytes,
            maximumIntermediateBytes: maximumIntermediateBytes
        )
        continuationPageCount = try increment(continuationPageCount)
        currentPageBuffer.release()
        currentPageBuffer = PageBuffer()
        self.currentPageID = nextPageID
    }

    private func makePage(
        _ buffer: PageBuffer,
        continuation: ByteString?
    ) throws -> RDFGraphPage {
        try RDFGraphPage(
            quads: buffer.quads,
            continuation: continuation,
            provenance: CompositionPageProvenance(
                composition: composition,
                origins: buffer.origins
            ),
            consistency: consistency
        )
    }

    private func increment(_ value: UInt32) throws -> UInt32 {
        let result = value.addingReportingOverflow(1)
        guard !result.overflow else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        return result.partialValue
    }
}
#endif

#endif
