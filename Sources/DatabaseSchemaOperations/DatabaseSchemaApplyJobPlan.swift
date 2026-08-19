@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseJobRuntime
import DatabaseKit
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire

public struct DatabaseSchemaApplyJobPlan:
    PersistentJobPayload,
    Sendable,
    Hashable
{
    package struct DataTarget: Sendable, Hashable {
        #if DATABASE_SERVER_MULTI_BASE
        package let resource: Security.Resource
        #endif
        package let generation: UInt64

        #if DATABASE_SERVER_MULTI_BASE
        package init(resource: Security.Resource, generation: UInt64) {
            self.resource = resource
            self.generation = generation
        }
        #else
        package init(generation: UInt64) {
            self.generation = generation
        }
        #endif
    }

    private static let formatVersion: UInt8 = 11

    package let previousFingerprint: SchemaFingerprint
    package let targetFingerprint: SchemaFingerprint
    package let indexPhysicalFingerprint: ByteString
    package let schemaVersion: Schema.Version
    package let idempotencyKey: String
    package let manifestBytes: ByteString
    package let dataTargets: [DataTarget]
    package let indexBuilds: [DatabaseIndexTransitionPlan.Target]
    package let indexRetirements: [DatabaseIndexTransitionPlan.Target]
    package let maximumWorkUnitsPerSlice: UInt64

    package var manifest: SchemaManifest {
        get throws {
            try SchemaManifest(canonicalBytes: manifestBytes)
        }
    }

    public func persistentJobValue()
        throws(PersistentJobPayloadError) -> FieldValue {
        do {
            #if DATABASE_SERVER_MULTI_BASE
            let encodedDataTargets = try dataTargets.map { target in
                let kind: UInt8
                let baseID: FieldValue
                switch target.resource {
                case .database:
                    kind = 0
                    baseID = .null
                case .base(let id):
                    kind = 1
                    baseID = .string(id.value)
                }
                return FieldValue.object(try FieldObject([
                    (key: "kind", value: .uint8(kind)),
                    (key: "baseID", value: baseID),
                    (key: "generation", value: .uint64(target.generation)),
                ]))
            }
            #else
            let encodedDataTargets = try dataTargets.map { target in
                return FieldValue.object(try FieldObject([
                    (key: "generation", value: .uint64(target.generation))
                    ]))
            }
            #endif
            let encodedIndexBuilds = try indexBuilds.map { target in
                let scope = Self.persistentScope(target.scope)
                return FieldValue.object(try FieldObject([
                    (key: "scopeKind", value: .uint8(scope.kind)),
                        (
                            key: "scopeIdentifier",
                            value: .string(scope.identifier)
                        ),
                        (key: "index", value: .string(target.identity.name)),
                    (
                            key: "directory",
                            value: scope.directory
                        ),
                        (
                            key: "definitionFingerprint",
                            value: .bytes(
                                target.identity.definitionFingerprint.bytes
                            )
                        ),
                    (
                            key: "layoutFingerprint",
                            value: .bytes(target.identity.layoutFingerprint)
                        ),
                    ]))
            }
            let encodedIndexRetirements = try indexRetirements.map { target in
                let scope = Self.persistentScope(target.scope)
                return FieldValue.object(try FieldObject([
                (key: "scopeKind", value: .uint8(scope.kind)),
                        (
                            key: "scopeIdentifier",
                            value: .string(scope.identifier)
                        ),
                        (key: "index", value: .string(target.identity.name)),
                        (
                            key: "directory",
                            value: scope.directory
                        ),
                        (
                            key: "definitionFingerprint",
                            value: .bytes(
                                target.identity.definitionFingerprint.bytes
                            )
                        ),
                        (
                            key: "layoutFingerprint",
                            value: .bytes(target.identity.layoutFingerprint)
                        ),
                    ]))
            }
            return .object(
                try FieldObject([
                    (key: "version", value: .uint8(Self.formatVersion)),
                (
                    key: "previousFingerprint",
                    value: .bytes(previousFingerprint.bytes)
                ),
                (
                    key: "targetFingerprint",
                    value: .bytes(targetFingerprint.bytes)
                ),
                (
                        key: "indexPhysicalFingerprint",
                        value: .bytes(indexPhysicalFingerprint)
                    ),
                    (key: "schemaVersion", value: Self.value(schemaVersion)),
                (key: "idempotencyKey", value: .string(idempotencyKey)),
                (key: "manifest", value: .bytes(manifestBytes)),
                (key: "dataTargets", value: .array(encodedDataTargets)),
                (key: "indexBuilds", value: .array(encodedIndexBuilds)),
                    (
                        key: "indexRetirements",
                        value: .array(encodedIndexRetirements)
                    ),
                (
                    key: "maximumWorkUnitsPerSlice",
                    value: .uint64(maximumWorkUnitsPerSlice)
                ),
            ]))
        } catch {
            throw .invalidValue("Schema apply job plan is not canonical")
        }
    }

    public init(
        persistentJobValue: FieldValue
    ) throws(PersistentJobPayloadError) {
        guard let fields = persistentJobValue.objectValue,
              fields.count == 11,
            fields["version"]?.uint8Value == Self.formatVersion,
              let previousBytes = fields["previousFingerprint"]?.bytesValue,
              let targetBytes = fields["targetFingerprint"]?.bytesValue,
            let indexPhysicalFingerprint =
                fields["indexPhysicalFingerprint"]?.bytesValue,
            indexPhysicalFingerprint.count
                == SHA256Accumulator.digestByteCount,
            let schemaVersion = Self.schemaVersion(fields["schemaVersion"]),
              let idempotencyKey = fields["idempotencyKey"]?.stringValue,
              !idempotencyKey.isEmpty,
              let manifestBytes = fields["manifest"]?.bytesValue,
              let dataTargetValues = fields["dataTargets"]?.arrayValue,
            let indexBuildValues = fields["indexBuilds"]?.arrayValue,
            let indexRetirementValues =
                fields["indexRetirements"]?.arrayValue,
              let maximumWorkUnitsPerSlice =
                fields["maximumWorkUnitsPerSlice"]?.uint64Value,
              maximumWorkUnitsPerSlice > 0 else {
            throw .invalidValue("Invalid schema apply job plan header")
        }
        let previousFingerprint: SchemaFingerprint
        let targetFingerprint: SchemaFingerprint
        let manifest: SchemaManifest
        do {
            previousFingerprint = try SchemaFingerprint(previousBytes)
            targetFingerprint = try SchemaFingerprint(targetBytes)
            manifest = try SchemaManifest(canonicalBytes: manifestBytes)
            guard try manifest.fingerprint() == targetFingerprint,
                  manifest.schema.version == schemaVersion else {
                throw DatabaseSchemaApplyJobError.corruptedPlan
            }
        } catch {
            throw .invalidValue("Invalid schema apply job manifest")
        }

        var dataTargets: [DataTarget] = []
        dataTargets.reserveCapacity(dataTargetValues.count)
        for value in dataTargetValues {
            #if DATABASE_SERVER_MULTI_BASE
            guard let fields = value.objectValue,
                  fields.count == 3,
                  let kind = fields["kind"]?.uint8Value,
                  let baseIDValue = fields["baseID"],
                  let generation = fields["generation"]?.uint64Value else {
                throw .invalidValue("Invalid schema apply data target")
            }
            let resource: Security.Resource
            switch kind {
            case 0 where baseIDValue.isNull:
                resource = .database
            case 1:
                guard let identifier = baseIDValue.stringValue else {
                    throw .invalidValue("Invalid schema apply data target")
                }
                do {
                    resource = .base(try Base.ID(identifier))
                } catch {
                    throw .invalidValue("Invalid schema apply data target")
                }
            default:
                throw .invalidValue("Invalid schema apply data target")
            }
            dataTargets.append(
                DataTarget(resource: resource, generation: generation)
            )
            #else
            guard let fields = value.objectValue,
                  fields.count == 1,
                  let generation = fields["generation"]?.uint64Value else {
                throw .invalidValue("Invalid schema apply data target")
            }
            dataTargets.append(DataTarget(generation: generation))
            #endif
        }
        #if DATABASE_SERVER_MULTI_BASE
        guard dataTargets == dataTargets.sorted(by: Self.dataTargetLessThan),
              Set(dataTargets.map { $0.resource }).count == dataTargets.count else {
            throw .invalidValue("Schema apply data targets are not canonical")
        }
        #else
        guard dataTargets.count == 1 else {
            throw .invalidValue("A single-database schema plan has one data target")
        }
        #endif

        var indexBuilds: [DatabaseIndexTransitionPlan.Target] = []
        indexBuilds.reserveCapacity(indexBuildValues.count)
        for value in indexBuildValues {
            guard let fields = value.objectValue,
                  fields.count == 6,
                let scopeKind = fields["scopeKind"]?.uint8Value,
                let scopeIdentifier =
                    fields["scopeIdentifier"]?.stringValue,
                !scopeIdentifier.isEmpty,
                  let index = fields["index"]?.stringValue,
                  !index.isEmpty,
                let directory = fields["directory"],
                let definitionBytes =
                    fields["definitionFingerprint"]?.bytesValue,
                let layoutFingerprint =
                    fields["layoutFingerprint"]?.bytesValue,
                layoutFingerprint.count
                    == SHA256Accumulator.digestByteCount
            else {
                throw .invalidValue("Invalid schema apply index target")
            }
            let definitionFingerprint: SchemaFingerprint
            do {
                definitionFingerprint = try SchemaFingerprint(definitionBytes)
            } catch {
                throw .invalidValue("Invalid schema apply index target")
            }
            let scope = try Self.indexScope(
                kind: scopeKind,
                identifier: scopeIdentifier,
                directory: directory
            )
            indexBuilds.append(
                try Self.indexTarget(
                    scope: scope,
                    index: index,
                    definitionFingerprint: definitionFingerprint,
                    layoutFingerprint: layoutFingerprint
                )
            )
        }
        guard indexBuilds == indexBuilds.sorted(by: Self.indexBuildLessThan),
            Set(indexBuilds).count == indexBuilds.count,
            Set(indexBuilds.map(\.identity.name)).count
                == indexBuilds.count else {
            throw .invalidValue("Schema apply index builds are not canonical")
        }

        var indexRetirements: [DatabaseIndexTransitionPlan.Target] = []
        indexRetirements.reserveCapacity(indexRetirementValues.count)
        for value in indexRetirementValues {
            guard let fields = value.objectValue,
                fields.count == 6,
                let scopeKind = fields["scopeKind"]?.uint8Value,
                let scopeIdentifier =
                    fields["scopeIdentifier"]?.stringValue,
                !scopeIdentifier.isEmpty,
                let index = fields["index"]?.stringValue,
                !index.isEmpty,
                let directory = fields["directory"],
                let fingerprintValue =
                    fields["definitionFingerprint"],
                let layoutFingerprint =
                    fields["layoutFingerprint"]?.bytesValue,
                layoutFingerprint.count
                    == SHA256Accumulator.digestByteCount
            else {
                throw .invalidValue("Invalid schema apply index retirement")
            }
            let scope = try Self.indexScope(
                kind: scopeKind,
                identifier: scopeIdentifier,
                directory: directory
            )
            guard let bytes = fingerprintValue.bytesValue else {
                throw .invalidValue(
                    "Invalid schema apply retirement fingerprint"
                )
            }
            let fingerprint: SchemaFingerprint
            do {
                fingerprint = try SchemaFingerprint(bytes)
            } catch {
                throw .invalidValue(
                    "Invalid schema apply retirement fingerprint"
                )
            }
            indexRetirements.append(
                try Self.indexTarget(
                    scope: scope,
                    index: index,
                    definitionFingerprint: fingerprint,
                    layoutFingerprint: layoutFingerprint
                )
            )
        }
        guard
            indexRetirements
                == indexRetirements.sorted(
                    by: Self.indexRetirementLessThan
                ), Set(indexRetirements).count == indexRetirements.count,
            Set(indexRetirements.map(\.identity.name)).count
                == indexRetirements.count,
            Set(indexBuilds).isDisjoint(with: Set(indexRetirements))
        else {
            throw .invalidValue(
                "Schema apply index retirements are not canonical"
            )
        }

        self.previousFingerprint = previousFingerprint
        self.targetFingerprint = targetFingerprint
        self.indexPhysicalFingerprint = indexPhysicalFingerprint
        self.schemaVersion = schemaVersion
        self.idempotencyKey = idempotencyKey
        self.manifestBytes = manifestBytes
        self.dataTargets = dataTargets
        self.indexBuilds = indexBuilds
        self.indexRetirements = indexRetirements
        self.maximumWorkUnitsPerSlice = maximumWorkUnitsPerSlice
    }

    package init(
        previousFingerprint: SchemaFingerprint,
        targetFingerprint: SchemaFingerprint,
        indexPhysicalFingerprint: ByteString,
        manifest: SchemaManifest,
        idempotencyKey: String,
        dataTargets: [DataTarget],
        indexBuilds: [DatabaseIndexTransitionPlan.Target],
        indexRetirements: [DatabaseIndexTransitionPlan.Target],
        maximumWorkUnitsPerSlice: UInt64
    ) throws {
        guard !idempotencyKey.isEmpty,
            maximumWorkUnitsPerSlice > 0,
            try manifest.fingerprint() == targetFingerprint,
            indexPhysicalFingerprint.count
                == SHA256Accumulator.digestByteCount,
            Set(indexBuilds).count == indexBuilds.count,
            Set(indexBuilds.map(\.identity.name)).count
                == indexBuilds.count,
            Set(indexRetirements).count == indexRetirements.count,
            Set(indexRetirements.map(\.identity.name)).count
                == indexRetirements.count,
            Set(indexBuilds).isDisjoint(with: Set(indexRetirements))
        else {
            throw DatabaseSchemaApplyJobError.corruptedPlan
        }
        self.previousFingerprint = previousFingerprint
        self.targetFingerprint = targetFingerprint
        self.indexPhysicalFingerprint = indexPhysicalFingerprint
        self.schemaVersion = manifest.schema.version
        self.idempotencyKey = idempotencyKey
        self.manifestBytes = try manifest.canonicalBytes()
        #if DATABASE_SERVER_MULTI_BASE
        self.dataTargets = dataTargets.sorted(by: Self.dataTargetLessThan)
        #else
        guard dataTargets.count == 1 else {
            throw DatabaseSchemaApplyJobError.corruptedPlan
        }
        self.dataTargets = dataTargets
        #endif
        self.indexBuilds = indexBuilds.sorted(by: Self.indexBuildLessThan)
        self.indexRetirements = indexRetirements.sorted(
            by: Self.indexRetirementLessThan
        )
        self.maximumWorkUnitsPerSlice = maximumWorkUnitsPerSlice
    }

    private static func indexBuildLessThan(
        _ lhs: DatabaseIndexTransitionPlan.Target,
        _ rhs: DatabaseIndexTransitionPlan.Target
    ) -> Bool {
        DatabaseIndexTransitionPlan.Target.stableLessThan(lhs, rhs)
    }

    private static func indexRetirementLessThan(
        _ lhs: DatabaseIndexTransitionPlan.Target,
        _ rhs: DatabaseIndexTransitionPlan.Target
    ) -> Bool {
        DatabaseIndexTransitionPlan.Target.stableLessThan(lhs, rhs)
    }

    private static func persistentScope(
        _ scope: DatabaseIndexStorageScope
    ) -> (kind: UInt8, identifier: String, directory: FieldValue) {
        switch scope {
        case .entity(let name, let components):
            return (
                0,
                name,
                .array(
                    components.map { component in
                        switch component {
                        case .staticPath(let value):
                            return .array([.uint8(0), .string(value)])
                        case .dynamicField(let name):
                            return .array([.uint8(1), .string(name)])
                        }
                    })
            )
        case .polymorphicGroup(let identifier, let path):
            return (
                1,
                identifier,
                .array(
                    path.map {
                        .array([.uint8(0), .string($0)])
                    })
            )
        }
    }

    private static func indexScope(
        kind: UInt8,
        identifier: String,
        directory: FieldValue
    ) throws(PersistentJobPayloadError) -> DatabaseIndexStorageScope {
        guard let values = directory.arrayValue else {
            throw .invalidValue("Invalid schema apply index directory")
        }
        var components: [DirectoryPathComponent] = []
        components.reserveCapacity(values.count)
        for value in values {
            guard let pair = value.arrayValue,
                pair.count == 2,
                let componentKind = pair[0].uint8Value,
                let componentValue = pair[1].stringValue,
                !componentValue.isEmpty
            else {
                throw .invalidValue("Invalid schema apply index directory")
            }
            switch componentKind {
            case 0:
                components.append(.staticPath(componentValue))
            case 1:
                components.append(.dynamicField(fieldName: componentValue))
            default:
                throw .invalidValue("Invalid schema apply index directory")
            }
        }
        switch kind {
        case 0:
            return .entity(
                name: identifier,
                directoryComponents: components
            )
        case 1:
            var path: [String] = []
            path.reserveCapacity(components.count)
            for component in components {
                guard case .staticPath(let value) = component else {
                    throw .invalidValue(
                        "Invalid polymorphic schema apply directory"
                    )
                }
                path.append(value)
            }
            return .polymorphicGroup(
                identifier: identifier,
                directoryPath: path
            )
        default:
            throw .invalidValue("Invalid schema apply index scope")
        }
    }

    private static func indexTarget(
        scope: DatabaseIndexStorageScope,
        index: String,
        definitionFingerprint: SchemaFingerprint,
        layoutFingerprint: ByteString
    ) throws(PersistentJobPayloadError) -> DatabaseIndexTransitionPlan.Target {
        do {
            return try DatabaseIndexTransitionPlan.Target(
                scope: scope,
                identity: try DatabaseIndexStorageIdentity(
                    name: index,
                    definitionFingerprint: definitionFingerprint,
                    layoutFingerprint: layoutFingerprint
                )
            )
        } catch {
            throw .invalidValue("Invalid schema apply index identity")
        }
    }

    #if DATABASE_SERVER_MULTI_BASE
    private static func dataTargetLessThan(
        _ lhs: DataTarget,
        _ rhs: DataTarget
    ) -> Bool {
        switch (lhs.resource, rhs.resource) {
        case (.database, .database):
            return false
        case (.database, .base):
            return true
        case (.base, .database):
            return false
        case (.base(let lhsID), .base(let rhsID)):
            return lhsID < rhsID
        }
    }
    #endif

    private static func value(_ version: Schema.Version) -> FieldValue {
        .array([
            .uint32(version.major),
            .uint32(version.minor),
            .uint32(version.patch),
        ])
    }

    private static func schemaVersion(
        _ value: FieldValue?
    ) -> Schema.Version? {
        guard let components = value?.arrayValue,
              components.count == 3,
              let major = components[0].uint32Value,
              let minor = components[1].uint32Value,
              let patch = components[2].uint32Value else {
            return nil
        }
        return Schema.Version(major, minor, patch)
    }
}
