import DatabaseMaintenanceOperations
import DatabaseSchemaOperations
import DatabaseJobRuntime
import DatabaseGraphOperations
import DatabaseMutationOperations
import DatabaseQueryOperations
import DatabaseCommandOperations
import DatabaseOperationCore
#if DATABASE_SERVER_MULTI_BASE
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire

/// Owns the bounded in-memory result window and spools durable continuation
/// pages incrementally, so peak retention is governed by the page limit rather
/// than by the size of the Composition result.
///
/// The framework Composition emit callback is `async throws`, so control-storage
/// work may run between two emissions. Spooling there is what keeps the request
/// intermediate-row claim bounded; deferring every page to `finish()` would
/// retain the whole result.
actor DatabaseCompositionQueryResultBuilder {
    private struct PageBuffer: Sendable {
        // These canonical budget units cover row, origin and producer-event
        // Arrays using the framework growth model, not allocator measurements.
        struct AppendAdmission: Sendable {
            let rows: UInt64
            let bytes: UInt64
            let capacity: Int
        }

        private static let rowContainerByteCount = UInt64(
            MemoryLayout<[DatabaseWire.QueryRow]>.stride
        )
        private static let originContainerByteCount = UInt64(
            MemoryLayout<[CompositionOrigin]>.stride
        )
        private static let contributorContainerByteCount = UInt64(
            MemoryLayout<[Base.ID]>.stride
        )
        private static let rowSlotByteCount = UInt64(
            max(1, MemoryLayout<DatabaseWire.QueryRow>.stride)
        )
        private static let originSlotByteCount = UInt64(
            max(1, MemoryLayout<CompositionOrigin>.stride)
        )
        private static let contributorSlotByteCount = UInt64(
            max(1, MemoryLayout<Base.ID>.stride)
        )
        private static let appendAdmissionByteCount: UInt64 = 16

        var rows: [DatabaseWire.QueryRow] = []
        var origins: [CompositionOrigin] = []
        var sourceEvents: [CompositionQueryRow] = []
        var reservation: DatabaseIntermediateReservation?
        private var accountedCapacity = 0

        var count: Int { rows.count }
        var hasReservation: Bool { reservation != nil }

        mutating func prepareAppend(
            footprint: (rows: UInt64, bytes: UInt64),
            origin: CompositionOrigin,
            workMeter: DatabaseWorkMeter
        ) throws -> AppendAdmission {
            let (requiredCount, countOverflow) = rows.count
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
                    Self.rowContainerByteCount
                )
                bytes = try Self.adding(
                    bytes,
                    Self.originContainerByteCount
                )
                bytes = try Self.adding(bytes, UInt64(MemoryLayout<[CompositionQueryRow]>.stride))
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
                rows.reserveCapacity(growth.capacity)
                origins.reserveCapacity(growth.capacity)
                sourceEvents.reserveCapacity(growth.capacity)
            }
            return AppendAdmission(
                rows: footprint.rows,
                bytes: bytes,
                capacity: growth.capacity
            )
        }

        mutating func appendReserved(
            row: DatabaseWire.QueryRow,
            event: CompositionQueryRow,
            using admission: AppendAdmission
        ) {
            rows.append(row)
            origins.append(event.origin)
            sourceEvents.append(event)
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
            rows.removeAll(keepingCapacity: false)
            origins.removeAll(keepingCapacity: false)
            sourceEvents.removeAll(keepingCapacity: false)
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
            let rowBytes = try multiplying(
                additionalSlots,
                Self.rowSlotByteCount
            )
            let originBytes = try multiplying(
                additionalSlots,
                Self.originSlotByteCount
            )
            return (
                capacity,
                try adding(try adding(rowBytes, originBytes),
                    multiplying(additionalSlots, UInt64(max(1, MemoryLayout<CompositionQueryRow>.stride))))
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

        static func adding(
            _ lhs: UInt64,
            _ rhs: UInt64
        ) throws -> UInt64 {
            let result = lhs.addingReportingOverflow(rhs)
            guard !result.overflow else {
                throw DatabaseQueryExecutionError.querySnapshotCorrupted
            }
            return result.partialValue
        }

        static func multiplying(
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
    private let schemaGeneration: UInt64
    private let consistency: DatabaseKit.DatabaseReadConsistency
    private let pageLimit: Int
    private let queryFingerprint: ByteString
    private let authorization: AuthorizationContext
    private let maximumIntermediateBytes: UInt64
    private let snapshotStore: DatabaseQuerySnapshotStore?
    private let workMeter: DatabaseWorkMeter

    private var phase: Phase = .accumulating
    private let columns: [QueryColumn]
    private var schemaReservation: DatabaseIntermediateReservation?
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
        columns: [QueryColumn],
        basePlacementGenerations: [Base.ID: UInt64],
        schemaGeneration: UInt64,
        consistency: DatabaseKit.DatabaseReadConsistency,
        pageLimit: Int,
        queryFingerprint: ByteString,
        authorization: AuthorizationContext,
        maximumIntermediateBytes: UInt64,
        snapshotStore: DatabaseQuerySnapshotStore?,
        workMeter: DatabaseWorkMeter
    ) throws {
        try QueryColumn.validate(columns)
        var schemaBytes = try PageBuffer.multiplying(
            UInt64(MemoryLayout<QueryColumn>.stride), UInt64(columns.capacity)
        )
        schemaBytes = try PageBuffer.adding(
            schemaBytes, UInt64(MemoryLayout<[QueryColumn]>.stride) + 64
        )
        for column in columns {
            schemaBytes = try PageBuffer.adding(
                schemaBytes, UInt64(column.name.utf8.count)
            )
        }
        self.schemaReservation = try workMeter.reserveIntermediate(
            bytes: schemaBytes, at: .resultMaterialization
        )
        self.columns = columns
        self.composition = composition
        self.basePlacementGenerations = basePlacementGenerations
        self.schemaGeneration = schemaGeneration
        self.consistency = consistency
        self.pageLimit = pageLimit
        self.queryFingerprint = queryFingerprint
        self.authorization = authorization
        self.maximumIntermediateBytes = maximumIntermediateBytes
        self.snapshotStore = snapshotStore
        self.workMeter = workMeter
    }

    /// Stages one row, spooling the current page first when it is already full.
    ///
    /// Column validation precedes destination admission. A failed encoding
    /// releases its destination claim; retained producer events keep their
    /// payload claims live until page transfer or authoritative abort.
    func append(_ event: CompositionQueryRow) async throws {
        let row = event.row
        guard phase == .accumulating else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        try Task.checkCancellation()

        try row.validate(columns: columns)

        if currentPageBuffer.count == pageLimit {
            phase = .spooling
            do {
                try await makeRoomForAdditionalRow()
            } catch {
                phase = .accumulating
                throw error
            }
            phase = .accumulating
        }

        let admission = try currentPageBuffer.prepareAppend(
            footprint: try event.retainedTransferFootprint(workMeter: workMeter),
            origin: event.origin,
            workMeter: workMeter
        )
        do {
            try Task.checkCancellation()
            let wireRow = try DatabaseQueryRowEncoder.encode(
                row,
                columns: columns
            )
            currentPageBuffer.appendReserved(
                row: wireRow,
                event: event,
                using: admission
            )
        } catch {
            currentPageBuffer.rollback(admission)
            throw error
        }
    }

    /// Spools the final page, publishes the manifest, and returns the response.
    func finish() async throws -> QueryRowPage {
        guard phase == .accumulating else {
            throw DatabaseQueryExecutionError.querySnapshotCorrupted
        }
        phase = .finishing
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
            guard writeReservation != nil || hasStagedReservation else {
                return
            }
        case .accumulating:
            break
        }
        phase = .aborting
        releaseStagedBuffers()
        do {
            if let writeReservation {
                guard let snapshotStore else {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
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

    private func releaseStagedBuffers() {
        schemaReservation?.release()
        schemaReservation = nil
        currentPageBuffer.release()
        if var firstPageBuffer {
            firstPageBuffer.release()
        }
        self.firstPageBuffer = nil
    }

    private func publish() async throws -> QueryRowPage {
        guard firstPageBuffer != nil else {
            let page = try makePage(currentPageBuffer, continuation: nil)
            try workMeter.recordOutput(page)
            if let writeReservation {
                guard let snapshotStore else {
                    throw DatabaseQueryExecutionError.querySnapshotCorrupted
                }
                try await snapshotStore.abortWrite(writeReservation)
            }
            releaseStagedBuffers()
            return page
        }
        guard let writeReservation,
              let snapshotStore,
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
        try workMeter.recordOutput(firstPage)
        try await snapshotStore.commitWrite(
            writeReservation,
            pageCount: continuationPageCount,
            totalPayloadBytes: totalPayloadBytes
        )

        // Both page windows retain their destination claims until the manifest
        // commit is authoritative. The first page can now transfer to output.
        releaseStagedBuffers()
        return firstPage
    }

    /// Publishes the full current page to control storage and starts a new one.
    ///
    /// The first full page remains staged with its destination claim until
    /// the manifest commits or the publication is aborted.
    private func makeRoomForAdditionalRow() async throws {
        guard let snapshotStore else {
            throw DatabaseQueryExecutionError.querySnapshotUnavailable(
                "the host did not provide durable Composition snapshot storage"
            )
        }
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
            firstPageBuffer = currentPageBuffer
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
    ) throws -> QueryRowPage {
        let provenance = try CompositionPageProvenance(
            composition: composition,
            origins: buffer.origins
        )
        return try QueryRowPage(
            columns: columns,
            rows: buffer.rows,
            continuation: continuation,
            provenance: provenance,
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
