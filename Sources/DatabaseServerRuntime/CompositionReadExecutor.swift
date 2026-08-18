#if DATABASE_SERVER_MULTIPLE_BASES
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import StorageKit

/// Server adapter state fixed to one semantic Composition selection.
package final class CompositionReadExecutor: Sendable {
    package let selection: CompositionSelection
    package let dataSource: CompositionDataSource
    private let container: DBContainer

    package init(
        selection: CompositionSelection,
        container: DBContainer,
        dataSource: CompositionDataSource
    ) {
        self.selection = selection
        self.container = container
        self.dataSource = dataSource
    }

    package var monotonicClock: any StorageMonotonicClock {
        container.monotonicClock
    }

    package var schema: Schema { container.schema }
    package var schemaGeneration: UInt64 { container.schemaGeneration }
    package var runtimeConfiguration: DatabaseRuntimeConfiguration {
        container.runtimeConfiguration
    }
    package var containerIdentity: ObjectIdentifier {
        ObjectIdentifier(container)
    }

    package func acquireReadLease() async throws -> DatabaseCompositionLease {
        try await dataSource.acquireReadLease()
    }

    package func resolveNamedRecord() async throws
        -> DatabaseCompositionRecord {
        let lease = try await acquireReadLease()
        guard let record = lease.namedRecord else {
            throw DatabaseCompositionAccessError.unavailable(selection)
        }
        return record
    }
}

#endif
