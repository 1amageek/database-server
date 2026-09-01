import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
#if DATABASE_SERVER_MULTI_BASE
#if DATABASE_OPERATIONS_GRAPH_INDEXES
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire

/// Owns the bounded in-memory quad window and spools durable continuation pages
/// incrementally, so peak retention is governed by the page limit rather than by
/// the size of the Composition RDF result.
///
/// The framework Composition emit callback is `async throws`, so control-storage
/// work may run between two emissions. Spooling there is what keeps the request
/// intermediate-row claim bounded; deferring every page to `finish()` would
/// retain the whole result.
actor DatabaseCompositionRDFResultBuilder {
    private struct PageBuffer: Sendable {
        // These values are canonical budget units for the two retained Array
        // containers. They mirror the framework retained-array growth model;
        // they are not allocator measurements.
        struct AppendAdmission: Sendable {
            let rows: UInt64
            let bytes: UInt64
            let capacity: Int
        }

        private static let quadContainerByteCount = UInt64(
            MemoryLayout<[RDFQuad]>.stride
        )
        private static let originContainerByteCount = UInt64(
            MemoryLayout<[CompositionOrigin]>.stride
        )
        private static let contributorContainerByteCount = UInt64(
            MemoryLayout<[Base.ID]>.stride
        )
        private static let quadSlotByteCount = UInt64(
            max(1, MemoryLayout<RDFQuad>.stride)
        )
        private static let originSlotByteCount = UInt64(
            max(1, MemoryLayout<CompositionOrigin>.stride)
        )
        private static let contributorSlotByteCount = UInt64(
            max(1, MemoryLayout<Base.ID>.stride)
        )
        private static let appendAdmissionByteCount: UInt64 = 16

        var quads: [RDFQuad] = []
        var origins: [CompositionOrigin] = []
        var reservation: DatabaseIntermediateReservation?
        private var accountedCapacity = 0

        var count: Int { quads.count }
        var hasReservation: Bool { reservation != nil }

        mutating func prepareAppend(
            footprint: DatabaseExecutionFootprint,
            origin: CompositionOrigin,
            workMeter: DatabaseWorkMeter
        ) throws -> AppendAdmission {
            guard footprint.rows == 1 else {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            let (requiredCount, countOverflow) = quads.count
                .addingReportingOverflow(1)
            guard !countOverflow else {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            let growth = try Self.growth(
                from: accountedCapacity,
                toFit: requiredCount
            )
            var bytes = try Self.adding(
                footprint.bytes,
                Self.appendAdmissionByteCount
            )
            bytes = try Self.adding(
                bytes,
                Self.appendAdmissionByteCount
            )
            if accountedCapacity == 0 {
                bytes = try Self.adding(
                    bytes,
                    Self.quadContainerByteCount
                )
                bytes = try Self.adding(
                    bytes,
                    Self.originContainerByteCount
                )
            }
            bytes = try Self.adding(
                bytes,
                try Self.contributorStorageByteCount(for: origin)
            )
            bytes = try Self.adding(bytes, growth.additionalByteCount)

            if let reservation {
                try reservation.reserveAdditional(
                    rows: footprint.rows,
                    bytes: bytes,
                    at: .resultMaterialization
                )
            } else {
                reservation = try workMeter.reserveIntermediate(
                    rows: footprint.rows,
                    bytes: bytes,
                    at: .resultMaterialization
                )
            }
            if growth.capacity > accountedCapacity {
                quads.reserveCapacity(growth.capacity)
                origins.reserveCapacity(growth.capacity)
            }
            return AppendAdmission(
                rows: footprint.rows,
                bytes: bytes,
                capacity: growth.capacity
            )
        }

        mutating func appendReserved(
            quad: RDFQuad,
            origin: CompositionOrigin,
            using admission: AppendAdmission
        ) {
            quads.append(quad)
            origins.append(origin)
            accountedCapacity = admission.capacity
        }

        mutating func rollback(_ admission: AppendAdmission) {
            guard let reservation else {
                preconditionFailure(
                    "Append rollback lost its intermediate reservation"
                )
            }
            do {
                try reservation.releasePartial(
                    rows: admission.rows,
                    bytes: admission.bytes
                )
            } catch {
                preconditionFailure(
                    "Append rollback violated its intermediate reservation"
                )
            }
        }

        mutating func release() {
            let reservation = self.reservation
            self.reservation = nil
            quads.removeAll(keepingCapacity: false)
            origins.removeAll(keepingCapacity: false)
            accountedCapacity = 0
            reservation?.release()
        }

        /// The first page is already the operation's final output. Its row
        /// count is governed by the output/page limits, so keeping it while
        /// the remaining pages are durably spooled must not also consume the
        /// intermediate-row budget.
        mutating func promoteToOutput() {
            let reservation = self.reservation
            self.reservation = nil
            accountedCapacity = 0
            reservation?.release()
        }

        private static func growth(
            from currentCapacity: Int,
            toFit requiredCount: Int
        ) throws -> (capacity: Int, additionalByteCount: UInt64) {
            guard currentCapacity >= 0,
                  requiredCount >= 0 else {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            guard requiredCount > currentCapacity else {
                return (currentCapacity, 0)
            }

            var capacity = max(1, currentCapacity)
            while capacity < requiredCount {
                let (nextCapacity, overflow) = capacity
                    .multipliedReportingOverflow(by: 2)
                guard !overflow else {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                capacity = nextCapacity
            }

            let additionalSlots = UInt64(capacity - currentCapacity)
            let quadBytes = try multiplying(
                additionalSlots,
                Self.quadSlotByteCount
            )
            let originBytes = try multiplying(
                additionalSlots,
                Self.originSlotByteCount
            )
            return (
                capacity,
                try adding(quadBytes, originBytes)
            )
        }

        private static func contributorStorageByteCount(
            for origin: CompositionOrigin
        ) throws -> UInt64 {
            guard case .derived(let contributors) = origin,
                  !contributors.isEmpty else {
                return 0
            }
            let growth = try capacityGrowth(
                from: 0,
                toFit: contributors.count,
                slotByteCount: Self.contributorSlotByteCount
            )
            return try adding(
                Self.contributorContainerByteCount,
                growth.additionalByteCount
            )
        }

        private static func capacityGrowth(
            from currentCapacity: Int,
            toFit requiredCount: Int,
            slotByteCount: UInt64
        ) throws -> (capacity: Int, additionalByteCount: UInt64) {
            guard currentCapacity >= 0,
                  requiredCount >= 0,
                  slotByteCount > 0 else {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            guard requiredCount > currentCapacity else {
                return (currentCapacity, 0)
            }

            var capacity = max(1, currentCapacity)
            while capacity < requiredCount {
                let (nextCapacity, overflow) = capacity
                    .multipliedReportingOverflow(by: 2)
                guard !overflow else {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                capacity = nextCapacity
            }
            let additionalSlots = UInt64(capacity - currentCapacity)
            return (
                capacity,
                try multiplying(additionalSlots, slotByteCount)
            )
        }

        private static func adding(
            _ lhs: UInt64,
            _ rhs: UInt64
        ) throws -> UInt64 {
            let result = lhs.addingReportingOverflow(rhs)
            guard !result.overflow else {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            return result.partialValue
        }

        private static func multiplying(
            _ lhs: UInt64,
            _ rhs: UInt64
        ) throws -> UInt64 {
            let result = lhs.multipliedReportingOverflow(by: rhs)
            guard !result.overflow else {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            return result.partialValue
        }
    }

    private enum Phase: Sendable, Equatable {
        case accumulating
        case spooling
        case finishing
        case aborting
        case completed
        case aborted
    }

    private let composition: CompositionResolution
    private let basePlacementGenerations: [Base.ID: UInt64]
    private let consistency: DatabaseKit.DatabaseReadConsistency
    private let schemaGeneration: UInt64
    private let pageLimit: Int
    private let maximumIntermediateBytes: UInt64
    private let queryFingerprint: ByteString
    private let authorization: AuthorizationContext
    private let snapshotStore: DatabaseQuerySnapshotStore
    private let workMeter: DatabaseWorkMeter

    private var phase: Phase = .accumulating
    private var footprintMeter: DatabaseRDFExecutionFootprintMeter?
    private var firstPageBuffer: PageBuffer?
    private var currentPageBuffer = PageBuffer()
    private var writeReservation:
        DatabaseQuerySnapshotStore.WriteReservation?
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
        self.consistency = consistency
        self.schemaGeneration = schemaGeneration
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

    /// Stages one quad, spooling the current page first when it is already full.
    func append(
        _ quad: RDFQuad,
        origin: CompositionOrigin
    ) async throws {
        guard phase == .accumulating,
              let footprintMeter else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        try Task.checkCancellation()
        let footprint = try footprintMeter.footprint(of: quad)

        if currentPageBuffer.count == pageLimit {
            phase = .spooling
            do {
                try await makeRoomForAdditionalQuad()
            } catch {
                phase = .accumulating
                throw error
            }
            phase = .accumulating
        }

        let admission = try currentPageBuffer.prepareAppend(
            footprint: footprint,
            origin: origin,
            workMeter: workMeter
        )
        do {
            try Task.checkCancellation()
            currentPageBuffer.appendReserved(
                quad: quad,
                origin: origin,
                using: admission
            )
        } catch {
            currentPageBuffer.rollback(admission)
            throw error
        }
    }

    /// Spools the final page, publishes the manifest, and returns the response.
    func finish() async throws -> RDFGraphPage {
        guard phase == .accumulating else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        phase = .finishing
        // The scratch worklist is only needed while quads are still arriving.
        releaseFootprintMeter()
        do {
            let page = try await publish()
            phase = .completed
            writeReservation = nil
            return page
        } catch {
            releaseStagedBuffers()
            phase = .aborted
            throw error
        }
    }

    /// Releases staged memory and, when present, aborts the durable write.
    func abort() async throws {
        switch phase {
        case .completed:
            return
        case .spooling, .finishing, .aborting:
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        case .aborted:
            guard writeReservation != nil
                || footprintMeter != nil
                || hasStagedReservation else {
                return
            }
        case .accumulating:
            break
        }
        phase = .aborting
        releaseStagedBuffers()
        releaseFootprintMeter()
        do {
            if let writeReservation {
                try await snapshotStore.abortWrite(writeReservation)
                self.writeReservation = nil
            }
            phase = .aborted
        } catch {
            phase = .aborted
            throw error
        }
    }

    private var hasStagedReservation: Bool {
        currentPageBuffer.hasReservation
            || firstPageBuffer?.hasReservation == true
    }

    private func releaseFootprintMeter() {
        let meter = footprintMeter
        footprintMeter = nil
        meter?.shutdown()
    }

    private func releaseStagedBuffers() {
        currentPageBuffer.release()
        if var firstPageBuffer {
            firstPageBuffer.release()
        }
        self.firstPageBuffer = nil
    }

    private func publish() async throws -> RDFGraphPage {
        guard firstPageBuffer != nil else {
            let page = try makePage(currentPageBuffer, continuation: nil)
            if let writeReservation {
                try await snapshotStore.abortWrite(writeReservation)
            }
            currentPageBuffer.release()
            return page
        }
        guard let writeReservation,
              let currentPageID,
              let firstContinuationPageID,
              let firstPageBuffer else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }

        try Task.checkCancellation()
        let lastPage = try makePage(currentPageBuffer, continuation: nil)
        totalPayloadBytes = try await snapshotStore.appendPage(
            lastPage,
            pageID: currentPageID,
            to: writeReservation,
            consumedPayloadBytes: totalPayloadBytes,
            maximumIntermediateBytes: maximumIntermediateBytes,
            workMeter: workMeter
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

        // The still-staging page and the write reservation are released only
        // after the manifest is authoritative. The first page released its
        // intermediate claim when it became the operation's output.
        releaseStagedBuffers()
        return firstPage
    }

    /// Publishes the full current page to control storage and starts a new one.
    ///
    /// The first full page becomes the operation's response, so it is retained
    /// but promoted out of the intermediate budget: its size is already
    /// governed by the request's output and page limits.
    private func makeRoomForAdditionalQuad() async throws {
        if firstPageBuffer == nil {
            let reservation: DatabaseQuerySnapshotStore.WriteReservation
            if let writeReservation {
                reservation = writeReservation
            } else {
                let newReservation = try await snapshotStore.beginWrite(
                    composition: composition,
                    basePlacementGenerations: basePlacementGenerations,
                    schemaGeneration: schemaGeneration,
                    queryFingerprint: queryFingerprint,
                    authorization: authorization
                )
                writeReservation = newReservation
                reservation = newReservation
            }
            let pageID = try await snapshotStore.reservePage(in: reservation)
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
            maximumIntermediateBytes: maximumIntermediateBytes,
            workMeter: workMeter
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
