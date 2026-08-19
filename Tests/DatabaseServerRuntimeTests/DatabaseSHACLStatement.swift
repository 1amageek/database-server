import DatabaseKit
import DatabaseKitFoundation
import DatabaseTypes

@Persistable
struct DatabaseSHACLStatement {
    #Directory<DatabaseSHACLStatement>("test", "database-server-shacl")

    var id: String
    var subject: RDFTerm
    var predicate: RDFTerm
    var object: RDFTerm
    var graph: RDFTerm

    #Index(
        .graph(
            name: "database_shacl_rdf",
            definition: .rdf(
                subject: \DatabaseSHACLStatement.subject,
                predicate: \DatabaseSHACLStatement.predicate,
                object: \DatabaseSHACLStatement.object,
        graph: \DatabaseSHACLStatement.graph
            )
        ))
}
