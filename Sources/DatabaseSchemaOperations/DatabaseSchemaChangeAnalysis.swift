import DatabaseJobRuntime
import DatabaseKit
@_spi(DatabaseExecution) import DatabaseWire

package struct DatabaseSchemaChangeAnalysis: Sendable {
    package let compatibility: SchemaExecuteOperation.Compatibility
    package let issues: [SchemaExecuteOperation.CompatibilityIssue]

    package static func analyze(
        current: Schema,
        target: Schema
    ) -> DatabaseSchemaChangeAnalysis {
        if current.entities.isEmpty {
            return DatabaseSchemaChangeAnalysis(
                compatibility: .initial,
                issues: []
            )
        }
        if current == target {
            return DatabaseSchemaChangeAnalysis(
                compatibility: .compatible,
                issues: []
            )
        }

        var migrationIssues = target.compatibilityReport(from: current)
            .allIssues
            .map(wireIssue)
        var advisoryIssues: [SchemaExecuteOperation.CompatibilityIssue] = []
        if target.version <= current.version {
            migrationIssues.append(
                issue(
                    code: "schema-version-not-advanced",
                    path: "version",
                    message: "A changed schema must advance the schema version beyond \(current.version)"
                )
            )
        }

        for targetEntity in target.entities {
            guard let currentEntity = current.entity(named: targetEntity.name) else {
                continue
            }
            let entityPath = "entities.\(targetEntity.name)"
            if targetEntity.identifierType != currentEntity.identifierType {
                migrationIssues.append(issue(
                    code: "identifier-type-changed",
                    path: "\(entityPath).identifierType",
                    message: "Entity identifier encoding changed"
                ))
            }
            if targetEntity.directoryComponents != currentEntity.directoryComponents
                || targetEntity.directoryLayer != currentEntity.directoryLayer {
                migrationIssues.append(issue(
                    code: "directory-changed",
                    path: "\(entityPath).directory",
                    message: "Entity storage directory changed"
                ))
            }
            if targetEntity.relationships != currentEntity.relationships {
                migrationIssues.append(issue(
                    code: "relationships-changed",
                    path: "\(entityPath).relationships",
                    message: "Relationship maintenance contract changed"
                ))
            }
            if targetEntity.ontology != currentEntity.ontology {
                migrationIssues.append(issue(
                    code: "ontology-binding-changed",
                    path: "\(entityPath).ontology",
                    message: "Ontology projection changed and requires reindexing"
                ))
            }
            if targetEntity.polymorphicMembership
                != currentEntity.polymorphicMembership {
                migrationIssues.append(issue(
                    code: "polymorphic-membership-changed",
                    path: "\(entityPath).polymorphicMembership",
                    message: "Polymorphic projection membership changed"
                ))
            }
            let report = targetEntity.compatibilityReport(from: currentEntity)
            for field in report.addedFields where !field.isOptional {
                migrationIssues.append(issue(
                    code: "required-field-added",
                    path: "\(entityPath).fields.\(field.name)",
                    message: "A required field was added to an existing entity"
                ))
            }
            for (field, currentCases) in currentEntity.enumMetadata {
                let targetCases = Set(targetEntity.enumMetadata[field] ?? [])
                if !Set(currentCases).isSubset(of: targetCases) {
                    migrationIssues.append(issue(
                        code: "enum-case-removed",
                        path: "\(entityPath).enumMetadata.\(field)",
                        message: "A previously valid enum case was removed"
                    ))
                }
            }
        }

        advisoryIssues.append(
            contentsOf: indexIssues(
                target.indexChanges(from: current)
            ))
        advisoryIssues.append(
            contentsOf: polymorphicIndexIssues(
                target.polymorphicIndexChanges(from: current)
            ))

        let uniqueMigrationIssues = deduplicate(migrationIssues)
        let uniqueIssues = deduplicate(migrationIssues + advisoryIssues)
        return DatabaseSchemaChangeAnalysis(
            compatibility: uniqueMigrationIssues.isEmpty
                ? .compatible
                : .requiresMigration,
            issues: uniqueIssues
        )
    }

    private static func indexIssues(
        _ changes: [IndexChange]
    ) -> [SchemaExecuteOperation.CompatibilityIssue] {
        changes.map { change in
            let identity = change.identity
            let path = "entities.\(identity.entityName).indexes.\(identity.name)"
            switch change {
            case .added:
                return issue(
                    code: "index-build-required",
                    path: path,
                    message: "The added index will be built before schema application completes"
                )
            case .removed:
                return issue(
                    code: "index-removed",
                    path: path,
                    message: "The removed index is no longer visible to the target schema"
                )
            case .replaced:
                return issue(
                    code: "index-rebuild-required",
                    path: path,
                    message: "The replacement index generation will be built before schema application completes"
                )
            }
        }
    }

    private static func polymorphicIndexIssues(
        _ changes: [PolymorphicIndexChange]
    ) -> [SchemaExecuteOperation.CompatibilityIssue] {
        changes.map { change in
            let identity = change.identity
            let path = "polymorphicGroups.\(identity.groupIdentifier).indexes.\(identity.name)"
            switch change {
            case .added:
                return issue(
                    code: "polymorphic-index-build-required",
                    path: path,
                    message: "The added polymorphic index will be built before schema application completes"
                )
            case .removed:
                return issue(
                    code: "polymorphic-index-removed",
                    path: path,
                    message: "The removed polymorphic index is no longer visible to the target schema"
                )
            case .replaced:
                return issue(
                    code: "polymorphic-index-rebuild-required",
                    path: path,
                    message:
                        "The replacement polymorphic index generation will be built before schema application completes"
                )
            }
        }
    }

    private static func wireIssue(
        _ issueValue: SchemaCompatibilityIssue
    ) -> SchemaExecuteOperation.CompatibilityIssue {
        switch issueValue {
        case .removedEntity(let entityName):
            return issue(
                code: "entity-removed",
                path: "entities.\(entityName)",
                message: issueValue.description
            )
        case .removedField(let entityName, let fieldName, _),
            .renumberedField(let entityName, let fieldName, _, _),
            .changedFieldEncoding(let entityName, let fieldName, _, _),
            .nonAppendOnlyFieldAddition(let entityName, let fieldName, _, _):
            return issue(
                code: schemaIssueCode(issueValue),
                path: "entities.\(entityName).fields.\(fieldName)",
                message: issueValue.description
            )
        }
    }

    private static func schemaIssueCode(
        _ issueValue: SchemaCompatibilityIssue
    ) -> String {
        switch issueValue {
        case .removedEntity: "entity-removed"
        case .removedField: "field-removed"
        case .renumberedField: "field-renumbered"
        case .changedFieldEncoding: "field-encoding-changed"
        case .nonAppendOnlyFieldAddition: "field-number-not-append-only"
        }
    }

    private static func issue(
        code: String,
        path: String,
        message: String
    ) -> SchemaExecuteOperation.CompatibilityIssue {
        SchemaExecuteOperation.CompatibilityIssue(
            code: code,
            path: path,
            message: message
        )
    }

    private static func deduplicate(
        _ issues: [SchemaExecuteOperation.CompatibilityIssue]
    ) -> [SchemaExecuteOperation.CompatibilityIssue] {
        var seen = Set<String>()
        return issues.filter {
            seen.insert("\($0.code)\u{0}\($0.path)").inserted
        }
    }
}
