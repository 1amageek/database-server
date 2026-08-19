import DatabaseKit
import DatabaseTypes

@Persistable
struct CanonicalRDFGraphStatement {
    #Directory<CanonicalRDFGraphStatement>(
        "test",
        "canonical-rdf-graph-statement"
    )

    var id: String
    var subject: RDFTerm
    var predicate: RDFTerm
    var object: RDFTerm
    var graph: RDFTerm?
    var weight: Double

    #Index(
        .graph(
            name: "rdf-graph",
            definition: .rdf(
                subject: \CanonicalRDFGraphStatement.subject,
                predicate: \CanonicalRDFGraphStatement.predicate,
                object: \CanonicalRDFGraphStatement.object,
        graph: \CanonicalRDFGraphStatement.graph
            ),
            includedFields: [\CanonicalRDFGraphStatement.weight]
        ))
}
