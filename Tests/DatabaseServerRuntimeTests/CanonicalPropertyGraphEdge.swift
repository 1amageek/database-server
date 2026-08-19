import DatabaseKit

@Persistable
struct CanonicalPropertyGraphEdge {
    #Directory<CanonicalPropertyGraphEdge>(
        "test",
        "canonical-property-graph-edge"
    )

    var id: String
    var source: String
    var label: String
    var target: String
    var weight: Double

    #Index(
        .graph(
            name: "graph",
            definition: .property(
                source: \CanonicalPropertyGraphEdge.source,
                label: .field(\CanonicalPropertyGraphEdge.label),
                target: \CanonicalPropertyGraphEdge.target,
                graph: nil,
                strategy: .tripleStore
            ),
            includedFields: [\CanonicalPropertyGraphEdge.weight]
        ))
}
