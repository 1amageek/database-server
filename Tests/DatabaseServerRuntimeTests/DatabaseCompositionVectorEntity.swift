#if DATABASE_OPERATIONS_TEST_VECTOR_INDEXES
import DatabaseKit
import DatabaseTypes

@Persistable
struct DatabaseCompositionVectorEntity {
    #Directory<DatabaseCompositionVectorEntity>(
        "test",
        "database-composition-vector"
    )

    var id: String
    var title: String
    var embedding: Vector

    #Index(
        .vector(
            name: "DatabaseCompositionVectorEntity_embedding",
            embedding: \DatabaseCompositionVectorEntity.embedding,
            dimensions: 2, metric: .euclidean
        ))
}
#endif
