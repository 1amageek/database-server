import DatabaseKit
import DatabaseRuntime
import DatabaseTypes

@Persistable
struct CatalogPartitionedEntity {
    #Directory<CatalogPartitionedEntity>(
        "test",
        "partition-catalog",
        \CatalogPartitionedEntity.tenantID
    )
    #Index(
        .ordered(
            name: "catalog_value",
            keys: [.ascending(\CatalogPartitionedEntity.value)]
        ))

    var id: String = ""
    var tenantID: String = ""
    var value: String = ""
}
