import DatabaseKit
import DatabaseKitFoundation
import DatabaseTypes

@Persistable
struct DatabaseGraphQueryStatement {
    #Directory<DatabaseGraphQueryStatement>(
        "test",
        "database-server-graph-query"
    )

    var id: String
    var subject: RDFTerm
    var predicate: RDFTerm
    var object: RDFTerm
    var graph: RDFTerm?

    #Index(
        .graph(
            name: "rdf_quad",
            definition: .rdf(
                subject: \DatabaseGraphQueryStatement.subject,
                predicate: \DatabaseGraphQueryStatement.predicate,
                object: \DatabaseGraphQueryStatement.object,
        graph: \DatabaseGraphQueryStatement.graph
            )
        ))
}
