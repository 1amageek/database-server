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
