import DatabaseKit
import DatabaseKitFoundation
import DatabaseTypes

@Persistable
struct DatabasePartitionedGraphQueryStatement {
    #Directory<DatabasePartitionedGraphQueryStatement>(
        "test",
        "database-server-partitioned-graph-query",
        \DatabasePartitionedGraphQueryStatement.calendar
    )

    #Index(
        .graph(
            name: "rdf_quad",
            definition: .rdf(
                subject: \DatabasePartitionedGraphQueryStatement.subject,
                predicate: \DatabasePartitionedGraphQueryStatement.predicate,
                object: \DatabasePartitionedGraphQueryStatement.object,
                graph: \DatabasePartitionedGraphQueryStatement.graph
            )
        )
    )

    var id: String
    var calendar: String
    var subject: RDFTerm
    var predicate: RDFTerm
    var object: RDFTerm
    var graph: RDFTerm?
}
