import DatabaseCommandOperations
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseGraphOperations
import DatabaseJobRuntime
import DatabaseKit
import DatabaseMaintenanceOperations
import DatabaseMutationOperations
import DatabaseOperationCore
import DatabaseQueryOperations
import DatabaseSchemaOperations
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire

public struct SchemaDescribeHandler: DatabaseOperationHandler {
    public typealias Operation = SchemaDescribeOperation

    public init() {}

    public func handle(
        _ request: EmptyOperationPayload,
        context: DatabaseOperationContext
    ) async throws -> SchemaDescribeOperation.Response {
        _ = request
        let executor = try context.requireControlExecutor()
        return try await executor.withTransaction(
            requiredAccess: .read,
            configuration: .readOnly
        ) { _ in
            let entities = try context.executor.schema.entities
                .sorted { $0.name < $1.name }
                .map {
                    try Self.describe(
                        $0,
                        runtimeConfiguration: executor.runtimeConfiguration
                    )
                }
            return SchemaDescribeOperation.Response(
                version: context.executor.schema.version,
                entities: entities
            )
        }
    }

    private static func describe(
        _ entity: Schema.Entity,
        runtimeConfiguration: DatabaseRuntimeConfiguration
    ) throws -> SchemaDescribeOperation.Entity {
        let fields = try entity.fields
            .sorted { $0.fieldNumber < $1.fieldNumber }
            .map { field -> SchemaDescribeOperation.Field in
                guard field.fieldNumber > 0,
                      let number = UInt32(exactly: field.fieldNumber) else {
                    throw SchemaDescriptionError.invalidFieldNumber(
                        entity: entity.name,
                        field: field.name,
                        number: field.fieldNumber
                    )
                }
                return SchemaDescribeOperation.Field(
                    number: number,
                    name: field.name,
                    type: valueType(for: field),
                    nullable: field.isOptional,
                    reference: try reference(
                        for: field,
                        entity: entity,
                        runtimeConfiguration: runtimeConfiguration
                    )
                )
            }

        let numbersByName = Dictionary(
            uniqueKeysWithValues: fields.map { ($0.name, $0.number) }
        )
        let indexes = try entity.indexes
            .sorted { $0.name < $1.name }
            .map { index -> SchemaDescribeOperation.Index in
                let fieldNumbers = try index.fieldNames.map { fieldName in
                    guard let number = numbersByName[fieldName] else {
                        throw SchemaDescriptionError.indexFieldNotFound(
                            entity: entity.name,
                            index: index.name,
                            field: fieldName
                        )
                    }
                    return number
                }
                return SchemaDescribeOperation.Index(
                    name: index.name,
                    type: index.type,
                    fields: fieldNumbers,
                    options: try options(for: index)
                )
            }
        return SchemaDescribeOperation.Entity(
            name: entity.name,
            fields: fields,
            indexes: indexes
        )
    }

    private static func valueType(
        for field: FieldSchema
    ) -> SchemaDescribeOperation.ValueType {
        if field.isArray { return .array }
        switch field.type {
        case .bool:
            return .bool
        case .int8:
            return .int8
        case .int16:
            return .int16
        case .int32:
            return .int32
        case .int64:
            return .int64
        case .uint8:
            return .uint8
        case .uint16:
            return .uint16
        case .uint32:
            return .uint32
        case .uint64:
            return .uint64
        case .float32:
            return .float32
        case .float64:
            return .float64
        case .decimal:
            return .decimal
        case .string, .enum:
            return .string
        case .uuid:
            return .uuid
        case .bytes:
            return .bytes
        case .date:
            return .date
        case .time:
            return .time
        case .dateTime:
            return .dateTime
        case .timestamp:
            return .timestamp
        case .timeSpan:
            return .timeSpan
        case .calendarPeriod:
            return .calendarPeriod
        case .geographicPoint:
            return .geographicPoint
        case .geographicPosition:
            return .geographicPosition
        case .vector:
            return .vector
        case .rdfTerm:
            return .rdfTerm
        case .nested, .object:
            return .object
        case .reference:
            return .reference
        }
    }

    private static func reference(
        for field: FieldSchema,
        entity: Schema.Entity,
        runtimeConfiguration: DatabaseRuntimeConfiguration
    ) throws -> SchemaDescribeOperation.Reference? {
        guard field.type == .reference else { return nil }
        guard runtimeConfiguration.entityRuntimes.registration(
            named: entity.name
        ) != nil,
              let descriptor = entity.relationships.first(where: {
                  $0.propertyName == field.name
              }) else {
            throw SchemaDescriptionError.relationshipMetadataNotFound(
                entity: entity.name,
                field: field.name
            )
        }
        let cardinality: SchemaDescribeOperation.ReferenceCardinality
        switch descriptor.cardinality {
        case .requiredToOne: cardinality = .requiredToOne
        case .optionalToOne: cardinality = .optionalToOne
        case .toMany: cardinality = .toMany
        }
        let deleteRule: SchemaDescribeOperation.ReferenceDeleteRule
        switch descriptor.deleteRule {
        case .nullify: deleteRule = .nullify
        case .cascade: deleteRule = .cascade
        case .deny: deleteRule = .deny
        case .noAction: deleteRule = .noAction
        }
        return SchemaDescribeOperation.Reference(
            targetEntity: descriptor.relatedTypeName,
            cardinality: cardinality,
            deleteRule: deleteRule
        )
    }

    private static func options(
        for index: IndexDescriptor) throws -> FieldObject {
        var values: [(key: String, value: FieldValue)] = [
            (
                key: "keyOrders",
                value: .array(
                    index.keys.map {
                        .string($0.order.rawValue)
                    })
            ),
            (
                key: "includedFields",
                value: .array(
                    index.includedFieldNames.map(FieldValue.string)
                )
            ),
        ]
        switch index.declaration.definition {
        case .ordered(_, _, let unique):
            values.append((key: "unique", value: .bool(unique)))
        case .aggregate(let function, _, _):
            switch function {
            case .approximateDistinct(let precision):
                values.append((key: "precision", value: .int64(Int64(precision))))
            case .percentile(let compression):
                values.append((key: "compression", value: .float64(compression)))
            case .count, .sum, .minimum, .maximum, .average, .nonNullCount:
                break
            }
        case .updateCount, .bitmap, .rank:
            break
        case .history(_, let retention):
            switch retention {
            case .keepAll:
                values.append((key: "retention", value: .string("keepAll")))
            case .keepLast(let count):
                values.append((key: "retention", value: .string("keepLast")))
                values.append((key: "retentionCount", value: .int64(Int64(count))))
            case .keepForDuration(let duration):
                values.append((key: "retention", value: .string("duration")))
                values.append((key: "retentionDuration", value: .timeSpan(duration)))
            }
        case .leaderboard(_, _, let window, let windowCount):
            let windowName: String
            switch window {
            case .hourly: windowName = "hourly"
            case .daily: windowName = "daily"
            case .weekly: windowName = "weekly"
            case .monthly: windowName = "monthly"
            case .custom: windowName = "custom"
            }
            values.append((key: "window", value: .string(windowName)))
            values.append((key: "windowDuration", value: .float64(window.durationSeconds)))
            values.append((key: "windowCount", value: .int64(Int64(windowCount))))
        case .vector(_, let dimensions, let metric):
            values.append((key: "dimensions", value: .int64(Int64(dimensions))))
            values.append((key: "metric", value: .string(metric.rawValue)))
        case .text(_, let mode):
            switch mode {
            case .fullText(
                let tokenizer,
                let storePositions,
                let ngramSize,
                let minimumTermLength
            ):
                values.append((key: "tokenizer", value: .string(tokenizer.rawValue)))
                values.append((key: "storePositions", value: .bool(storePositions)))
                values.append((key: "ngramSize", value: .int64(Int64(ngramSize))))
                values.append((key: "minimumTermLength", value: .int64(Int64(minimumTermLength))))
            case .autocomplete(
                let minimumPrefixLength,
                let maximumPrefixLength
            ):
                values.append((key: "minimumPrefixLength", value: .int64(Int64(minimumPrefixLength))))
                values.append((key: "maximumPrefixLength", value: .int64(Int64(maximumPrefixLength))))
            }
        case .spatial(_, let encoding, let level):
            values.append((key: "encoding", value: .string(encoding.rawValue)))
            values.append((key: "level", value: .int64(Int64(level))))
        case .graph(let graph, _):
            switch graph {
            case .property(_, let label, _, _, let strategy):
                let labelMode: String
                switch label {
                case .field: labelMode = "field"
                case .implicit: labelMode = "implicit"
                }
                values.append((key: "label", value: .string(labelMode)))
                values.append((key: "strategy", value: .string(strategy.rawValue)))
            case .rdf:
                break
            case .ontologyProjection(let individualIRIBase, let graph):
                values.append((key: "individualIRIBase", value: .string(individualIRIBase)))
                if let graph {
                    values.append((key: "graph", value: .rdfTerm(graph.term)))
                }
            }
        case .custom(let definition):
            values.append(
                contentsOf: definition.parameters.map {
            (key: "parameters.\($0.key)", value: $0.value)
                })
        }
        return try FieldObject(
            values.sorted { $0.key < $1.key }
        )
    }
}
