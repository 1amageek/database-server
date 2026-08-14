public enum NativeDatabaseStorageConfiguration: Sendable, Hashable {
    public struct PostgreSQL: Sendable, Hashable {
        public enum Connection: Sendable, Hashable {
            case tcp(host: String, port: Int)
            case unixSocket(path: String)
        }

        public enum TLSMode: String, Sendable, Hashable {
            case disable
            case require
        }

        public enum SchemaManagement: String, Sendable, Hashable {
            case createIfNeeded
            case assumeExists
        }

        public let connection: Connection
        public let username: String
        public let passwordFilePath: String?
        public let database: String
        public let tls: TLSMode
        public let tableName: String
        public let schemaManagement: SchemaManagement

        public init(
            connection: Connection,
            username: String,
            passwordFilePath: String? = nil,
            database: String,
            tls: TLSMode = .disable,
            tableName: String = "kv_store",
            schemaManagement: SchemaManagement = .createIfNeeded
        ) {
            self.connection = connection
            self.username = username
            self.passwordFilePath = passwordFilePath
            self.database = database
            self.tls = tls
            self.tableName = tableName
            self.schemaManagement = schemaManagement
        }
    }

    case sqliteMemory
    case sqliteFile(path: String)
    case postgreSQL(PostgreSQL)
    case foundationDB(clusterFilePath: String)
}

#if DATABASE_SERVER_HOST_MULTIPLE_BASES
/// Host-owned description of one independently transacted storage domain.
public struct NativeDatabaseStorageDomainConfiguration: Sendable, Hashable {
    public let id: String
    public let namespacePath: [String]
    public let storage: NativeDatabaseStorageConfiguration

    public init(
        id: String,
        namespacePath: [String],
        storage: NativeDatabaseStorageConfiguration
    ) {
        self.id = id
        self.namespacePath = namespacePath
        self.storage = storage
    }
}

/// Host-owned mapping from a placement name to one domain namespace.
public struct NativeDatabaseStoragePlacementConfiguration:
    Sendable,
    Hashable
{
    public let id: String
    public let domainID: String
    public let path: [String]

    public init(id: String, domainID: String, path: [String]) {
        self.id = id
        self.domainID = domainID
        self.path = path
    }
}

/// Complete native-host topology. Engines are opened only by the host and are
/// transferred exactly once into the framework container.
public struct NativeDatabaseStorageTopologyConfiguration:
    Sendable,
    Hashable
{
    public let controlDomainID: String
    public let domains: [NativeDatabaseStorageDomainConfiguration]
    public let placements: [NativeDatabaseStoragePlacementConfiguration]
    public let defaultPlacementID: String

    public init(
        controlDomainID: String,
        domains: [NativeDatabaseStorageDomainConfiguration],
        placements: [NativeDatabaseStoragePlacementConfiguration],
        defaultPlacementID: String
    ) {
        self.controlDomainID = controlDomainID
        self.domains = domains
        self.placements = placements
        self.defaultPlacementID = defaultPlacementID
    }

    public static func single(
        storage: NativeDatabaseStorageConfiguration,
        namespacePath: [String]
    ) -> Self {
        Self(
            controlDomainID: "primary",
            domains: [
                NativeDatabaseStorageDomainConfiguration(
                    id: "primary",
                    namespacePath: namespacePath,
                    storage: storage
                ),
            ],
            placements: [
                NativeDatabaseStoragePlacementConfiguration(
                    id: "default",
                    domainID: "primary",
                    path: ["bases"]
                ),
            ],
            defaultPlacementID: "default"
        )
    }
}
#endif
