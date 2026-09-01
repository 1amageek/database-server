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

#if DATABASE_SERVER_HOST_MULTI_BASE
/// Host-owned description of one independently transacted storage domain.
public struct NativeDatabaseStorageDomainConfiguration: Sendable, Hashable {
    public let id: String
    /// Directory path of this domain's database root.
    public let rootPath: [String]
    public let storage: NativeDatabaseStorageConfiguration

    public init(
        id: String,
        rootPath: [String],
        storage: NativeDatabaseStorageConfiguration
    ) {
        self.id = id
        self.rootPath = rootPath
        self.storage = storage
    }
}

/// Host-owned mapping from a placement name to one storage domain.
///
/// A Base Partition's address is fixed below the database root of its domain,
/// so a placement carries no path of its own: naming the domain fully
/// determines where a newly provisioned Base is created.
public struct NativeDatabaseStoragePlacementConfiguration:
    Sendable,
    Hashable
{
    public let id: String
    public let domainID: String

    public init(id: String, domainID: String) {
        self.id = id
        self.domainID = domainID
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
        rootPath: [String]
    ) -> Self {
        Self(
            controlDomainID: "primary",
            domains: [
                NativeDatabaseStorageDomainConfiguration(
                    id: "primary",
                    rootPath: rootPath,
                    storage: storage
                ),
            ],
            placements: [
                NativeDatabaseStoragePlacementConfiguration(
                    id: "default",
                    domainID: "primary"
                ),
            ],
            defaultPlacementID: "default"
        )
    }
}
#endif
