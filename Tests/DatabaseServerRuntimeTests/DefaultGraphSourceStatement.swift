import DatabaseKit
import DatabaseKitFoundation
import DatabaseTypes

@Persistable
struct DefaultGraphSourceStatement {
    #Directory<DefaultGraphSourceStatement>(
        "test",
        "database-server-default-graph-source"
    )

    var id: String
    var subject: RDFTerm
    var predicate: RDFTerm
    var object: RDFTerm

    #Index(
        .graph(
            name: "default_rdf",
            definition: .rdf(
                subject: \DefaultGraphSourceStatement.subject,
                predicate: \DefaultGraphSourceStatement.predicate,
                object: \DefaultGraphSourceStatement.object,
                graph: nil
            )
        ))
}
