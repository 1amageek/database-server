import DatabaseKit
import DatabaseTypes

@Persistable
struct DatabaseGraphSourceEdge {
    #Directory<DatabaseGraphSourceEdge>("test", "database-graph-source")

    var id: String = ""
    var source: String = ""
    var label: String = ""
    var target: String = ""
    var graph: String? = nil
    var weight: Double = 0

    #Index(
        .graph(
            name: "source_graph",
            definition: .property(
                source: \DatabaseGraphSourceEdge.source,
                label: .field(\DatabaseGraphSourceEdge.label),
                target: \DatabaseGraphSourceEdge.target,
        graph: \DatabaseGraphSourceEdge.graph,
                strategy: .adjacency
            ),
            includedFields: [\DatabaseGraphSourceEdge.weight]
        ))

    #Index(
        .graph(
            name: "source_graph_default",
            definition: .property(
                source: \DatabaseGraphSourceEdge.source,
                label: .field(\DatabaseGraphSourceEdge.label),
                target: \DatabaseGraphSourceEdge.target,
                graph: nil,
                strategy: .adjacency
            ),
            includedFields: [\DatabaseGraphSourceEdge.weight]
        ))
}
