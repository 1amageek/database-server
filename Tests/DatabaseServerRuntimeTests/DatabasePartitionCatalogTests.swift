import DatabaseKit
import DatabaseRuntime
import DatabaseTypes
import StorageKit
import TestSupport
import Testing

@_spi(DatabaseExecution) @testable import DatabaseEngine

@Suite("Database Partition Catalog Tests", .serialized)
struct DatabasePartitionCatalogTests {
    @Test("Dynamic partitions persist and page across container recreation")
    func persistsAndPagesPartitions() async throws {
        let engine = InMemoryEngine()
        let firstContainer = try await makeContainer(engine: engine)

        var firstPath = DirectoryPath<CatalogPartitionedEntity>()
        firstPath.set(CatalogPartitionedEntity.fields.tenantID, to: "tenant-a")
        _ = try await firstContainer.testBaseDirectory(
            for: CatalogPartitionedEntity.self,
            path: firstPath
        )
        _ = try await firstContainer.testBaseDirectory(
            for: CatalogPartitionedEntity.self,
            path: firstPath
        )

        var secondPath = DirectoryPath<CatalogPartitionedEntity>()
        secondPath.set(CatalogPartitionedEntity.fields.tenantID, to: "tenant-b")
        _ = try await firstContainer.testBaseDirectory(
            for: CatalogPartitionedEntity.self,
            path: secondPath
        )

        let firstPage = try await firstContainer.withTestBaseOperation {
            try await firstContainer.partitionCatalogPage(
                entity: CatalogPartitionedEntity.persistableType,
                limit: 1
            )
        }
        #expect(firstPage.entries.count == 1)
        let continuation = try #require(firstPage.continuation)

        let recreatedContainer = try await makeContainer(engine: engine)
        let secondPage = try await recreatedContainer.withTestBaseOperation {
            try await recreatedContainer.partitionCatalogPage(
                entity: CatalogPartitionedEntity.persistableType,
                continuation: continuation,
                limit: 1
            )
        }
        #expect(secondPage.entries.count == 1)
        // A page that ends exactly on its limit still carries the path of the
        // last partition it reported. The walk is not one snapshot: resuming
        // re-descends that path, so a partition created between two pages is
        // reported instead of being skipped. Enumeration therefore ends with an
        // empty page rather than by suppressing the continuation of a full one.
        let finalContinuation = try #require(secondPage.continuation)
        let finalPage = try await recreatedContainer.withTestBaseOperation {
            try await recreatedContainer.partitionCatalogPage(
                entity: CatalogPartitionedEntity.persistableType,
                continuation: finalContinuation,
                limit: 1
            )
        }
        #expect(finalPage.entries.isEmpty)
        #expect(finalPage.continuation == nil)

        let values = Set(
            (firstPage.entries + secondPage.entries).compactMap {
                $0.partitions["tenantID"]
            }
        )
        #expect(values == [.string("tenant-a"), .string("tenant-b")])
    }

    @Test("Partition path components preserve FieldValue types")
    func preservesPartitionTypes() throws {
        let stringComponent = try DirectoryComponentCodec.encode(.string("1"))
        let integerComponent = try DirectoryComponentCodec.encode(.int64(1))

        #expect(stringComponent != integerComponent)
        #expect(
            try DirectoryComponentCodec.decode(stringComponent) == .string("1")
        )
        #expect(
            try DirectoryComponentCodec.decode(integerComponent) == .int64(1)
        )
    }

    @Test("Missing dynamic partitions are rejected before directory I/O")
    func rejectsMissingPartition() {
        #expect(throws: DirectoryPathError.self) {
            _ = try AnyDirectoryPath(for: CatalogPartitionedEntity.self)
        }
        #expect(throws: DirectoryPathError.self) {
            _ = try AnyDirectoryPath(
                DirectoryPath<CatalogPartitionedEntity>()
            )
        }
    }

    private func makeContainer(engine: InMemoryEngine) async throws -> DBContainer {
        try await DBContainer.open(
            for: try Schema(
                entities: [try CatalogPartitionedEntity.schemaEntity],
                version: Schema.Version(1, 0, 0)
            ),
            configuration: .testing(storageEngine: engine),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-tests",
                    revision: 1
                ),
                entityRuntimes: [try DatabaseFrameworkRuntime.entity(CatalogPartitionedEntity.self)]
            ),
            security: .testingDisabled
        )
    }
}
