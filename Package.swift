// swift-tools-version: 6.4
import PackageDescription

let runtimeFeatureNames: Set<String> = [
    "ScalarIndexes",
    "VectorIndexes",
    "FullTextIndexes",
    "SpatialIndexes",
    "RankIndexes",
    "BitmapIndexes",
    "VersionIndexes",
    "PermutedIndexes",
    "GraphIndexes",
    "AggregationIndexes",
    "LeaderboardIndexes",
    "Relationships",
]

let runtimeTraits = Set(runtimeFeatureNames.map { Trait.trait(name: $0) })
    .union([
        .trait(name: "SQLiteBackend"),
        .trait(name: "PostgreSQLBackend"),
        .trait(name: "FoundationDBBackend"),
        .trait(
            name: "AllStorageBackends",
            enabledTraits: [
                "SQLiteBackend",
                "PostgreSQLBackend",
                "FoundationDBBackend",
            ]
        ),
        .trait(name: "MultipleBases"),
        .trait(
            name: "AllRuntimeFeatures",
            enabledTraits: runtimeFeatureNames
        ),
        .default(enabledTraits: ["AllRuntimeFeatures", "SQLiteBackend"]),
    ])

let frameworkTraits = Set(
    runtimeFeatureNames.map {
        Package.Dependency.Trait.trait(
            name: $0,
            condition: .when(traits: [$0])
        )
    }
).union([
    .trait(
        name: "SQLite",
        condition: .when(traits: ["SQLiteBackend"])
    ),
    .trait(
        name: "PostgreSQL",
        condition: .when(traits: ["PostgreSQLBackend"])
    ),
    .trait(
        name: "FoundationDB",
        condition: .when(traits: ["FoundationDBBackend"])
    ),
    .trait(
        name: "MultipleBases",
        condition: .when(traits: ["MultipleBases"])
    ),
])

let databaseKitTraits: Set<Package.Dependency.Trait> = [
    .trait(
        name: "MultipleBases",
        condition: .when(traits: ["MultipleBases"])
    ),
]

let foundationDBClientLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(
        ["-Xlinker", "-rpath", "-Xlinker", "/usr/local/lib"],
        .when(platforms: [.macOS], traits: ["FoundationDBBackend"])
    ),
]

let package = Package(
    name: "database-server",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(
            name: "database-server",
            targets: ["DatabaseServer"]
        ),
    ],
    traits: runtimeTraits,
    dependencies: [
        .package(
            url: "https://github.com/1amageek/database-framework.git",
            from: "26.0818.0",
            traits: frameworkTraits
        ),
        .package(
            url: "https://github.com/1amageek/storage-kit.git",
            from: "26.0807.0"
        ),
        .package(
            url: "https://github.com/1amageek/fdb-swift-bindings.git",
            exact: "0.3.3"
        ),
        .package(
            url: "https://github.com/1amageek/database-kit.git",
            from: "26.0818.0",
            traits: databaseKitTraits
        ),
        .package(
            url: "https://github.com/1amageek/database-types.git",
            from: "26.0730.0"
        ),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            exact: "2.26.0"
        ),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird-websocket.git",
            exact: "2.7.0"
        ),
        .package(
            url: "https://github.com/swift-server/swift-service-lifecycle.git",
            exact: "2.11.0"
        ),
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            exact: "4.5.1"
        ),
        .package(
            url: "https://github.com/apple/swift-argument-parser.git",
            exact: "1.8.2"
        ),
        .package(
            url: "https://github.com/apple/swift-http-types.git",
            exact: "1.6.0"
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            exact: "2.101.3"
        ),
        .package(
            url: "https://github.com/apple/swift-nio-ssl.git",
            exact: "2.37.2"
        ),
        .package(
            url: "https://github.com/apple/swift-log.git",
            from: "1.7.0"
        ),
        .package(
            url: "https://github.com/1amageek/swift-testing-heartbeat.git",
            from: "0.1.0"
        ),
    ],
    targets: [
        // DatabaseOperationCore - Shared operation admission and resource contracts
        .target(
            name: "DatabaseOperationCore",
            dependencies: [
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "StorageKit", package: "storage-kit"),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_SERVER_MULTIPLE_BASES",
                    .when(traits: ["MultipleBases"])
                ),
            ]
        ),
        // DatabaseCommandOperations - Application command contracts and registries
        .target(
            name: "DatabaseCommandOperations",
            dependencies: [
                "DatabaseOperationCore",
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
            ]
        ),
        // DatabaseQueryOperations - Wire query admission and paging
        .target(
            name: "DatabaseQueryOperations",
            dependencies: [
                "DatabaseOperationCore",
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "QueryAST", package: "database-framework"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(
                    name: "GraphIndex",
                    package: "database-framework",
                    condition: .when(traits: ["GraphIndexes"])
                ),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_SERVER_MULTIPLE_BASES",
                    .when(traits: ["MultipleBases"])
                ),
                .define(
                    "DATABASE_QUERY_OPERATIONS_GRAPH_INDEXES",
                    .when(traits: ["GraphIndexes"])
                ),
            ]
        ),
        // DatabaseMutationOperations - Wire mutation state and admission adapters
        .target(
            name: "DatabaseMutationOperations",
            dependencies: [
                "DatabaseOperationCore",
                "DatabaseQueryOperations",
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "StorageKit", package: "storage-kit"),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_SERVER_MULTIPLE_BASES",
                    .when(traits: ["MultipleBases"])
                ),
                .define(
                    "DATABASE_MUTATION_OPERATIONS_GRAPH_INDEXES",
                    .when(traits: ["GraphIndexes"])
                ),
            ]
        ),
        // DatabaseGraphOperations - Graph wire paging and execution adapters
        .target(
            name: "DatabaseGraphOperations",
            dependencies: [
                "DatabaseOperationCore",
                "DatabaseQueryOperations",
                "DatabaseMutationOperations",
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(
                    name: "GraphIndex",
                    package: "database-framework",
                    condition: .when(traits: ["GraphIndexes"])
                ),
                .product(
                    name: "OntologyIndex",
                    package: "database-framework",
                    condition: .when(traits: ["GraphIndexes"])
                ),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "StorageKit", package: "storage-kit"),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_SERVER_MULTIPLE_BASES",
                    .when(traits: ["MultipleBases"])
                ),
                .define(
                    "DATABASE_GRAPH_OPERATIONS_ENABLED",
                    .when(traits: ["GraphIndexes"])
                ),
            ]
        ),
        // DatabaseJobRuntime - Durable job state, storage, and scheduling contracts
        .target(
            name: "DatabaseJobRuntime",
            dependencies: [
                "DatabaseOperationCore",
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "StorageKit", package: "storage-kit"),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_SERVER_MULTIPLE_BASES",
                    .when(traits: ["MultipleBases"])
                ),
            ]
        ),
        // DatabaseSchemaOperations - Schema compatibility and runtime assembly
        .target(
            name: "DatabaseSchemaOperations",
            dependencies: [
                "DatabaseJobRuntime",
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseRuntime", package: "database-framework"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_SERVER_MULTIPLE_BASES",
                    .when(traits: ["MultipleBases"])
                ),
            ]
        ),
        // DatabaseMaintenanceOperations - Index and maintenance state/planning
        .target(
            name: "DatabaseMaintenanceOperations",
            dependencies: [
                "DatabaseJobRuntime",
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "StorageKit", package: "storage-kit"),
            ]
        ),
        // DatabaseAdministrationOperations - Multiple-Base lifecycle state
        .target(
            name: "DatabaseAdministrationOperations",
            dependencies: [
                "DatabaseJobRuntime",
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_SERVER_MULTIPLE_BASES",
                    .when(traits: ["MultipleBases"])
                ),
                .define(
                    "DATABASE_ADMINISTRATION_OPERATIONS_ENABLED",
                    .when(traits: ["MultipleBases"])
                ),
            ]
        ),
        // DatabaseServerRuntime - Standalone server operation dispatch
        .target(
            name: "DatabaseServerRuntime",
            dependencies: [
                "DatabaseOperationCore",
                "DatabaseCommandOperations",
                "DatabaseQueryOperations",
                "DatabaseMutationOperations",
                "DatabaseGraphOperations",
                "DatabaseJobRuntime",
                "DatabaseSchemaOperations",
                "DatabaseMaintenanceOperations",
                .target(
                    name: "DatabaseAdministrationOperations",
                    condition: .when(traits: ["MultipleBases"])
                ),
                .product(
                    name: "DatabaseMath",
                    package: "database-framework",
                    condition: .when(traits: ["GraphIndexes"])
                ),
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseRuntime", package: "database-framework"),
                .product(
                    name: "GraphIndex",
                    package: "database-framework",
                    condition: .when(traits: ["GraphIndexes"])
                ),
                .product(
                    name: "OntologyIndex",
                    package: "database-framework",
                    condition: .when(traits: ["GraphIndexes"])
                ),
                .product(
                    name: "RelationshipIndex",
                    package: "database-framework",
                    condition: .when(traits: ["Relationships"])
                ),
                .product(name: "QueryAST", package: "database-framework"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "StorageKit", package: "storage-kit"),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_SERVER_MULTIPLE_BASES",
                    .when(traits: ["MultipleBases"])
                ),
                .define(
                    "DATABASE_OPERATIONS_GRAPH_INDEXES",
                    .when(traits: ["GraphIndexes"])
                ),
                .define(
                    "DATABASE_OPERATIONS_RELATIONSHIPS",
                    .when(traits: ["Relationships"])
                ),
                .define(
                    "DATABASE_OPERATIONS_VECTOR_INDEXES",
                    .when(traits: ["VectorIndexes"])
                ),
            ]
        ),
        // Test Support (shared test utilities)
        .target(
            name: "TestSupport",
            dependencies: [
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseRuntime", package: "database-framework"),
                .product(name: "ScalarIndex", package: "database-framework"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "StorageKit", package: "storage-kit"),
                .product(name: "FDBStorage", package: "storage-kit",
                         condition: .when(traits: ["FoundationDBBackend"])),
                .product(name: "FoundationDB", package: "fdb-swift-bindings",
                         condition: .when(traits: ["FoundationDBBackend"])),
                .product(name: "PostgreSQLStorage", package: "storage-kit",
                         condition: .when(traits: ["PostgreSQLBackend"])),
                .product(name: "TestHeartbeat", package: "swift-testing-heartbeat"),
            ],
            path: "Tests/Shared",
            swiftSettings: [
                .define("FOUNDATION_DB", .when(traits: ["FoundationDBBackend"])),
                .define("POSTGRESQL", .when(traits: ["PostgreSQLBackend"])),
                .define(
                    "DATABASE_SERVER_MULTIPLE_BASES",
                    .when(traits: ["MultipleBases"])
                ),
            ]
        ),
        // DatabaseServerRuntime tests
        .testTarget(
            name: "DatabaseServerRuntimeTests",
            dependencies: [
                "DatabaseServerRuntime",
                "DatabaseOperationCore",
                "DatabaseCommandOperations",
                "DatabaseQueryOperations",
                "DatabaseMutationOperations",
                "DatabaseGraphOperations",
                "DatabaseJobRuntime",
                "DatabaseSchemaOperations",
                "DatabaseMaintenanceOperations",
                "DatabaseAdministrationOperations",
                "DatabaseServerFoundation",
                .product(name: "DatabaseRuntime", package: "database-framework"),
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "GraphIndex", package: "database-framework"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseKitFoundation", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "StorageKit", package: "storage-kit"),
                "TestSupport",
                .product(name: "Database", package: "database-framework"),
                .product(name: "SQLiteStorage", package: "storage-kit", condition: .when(traits: ["SQLiteBackend"])),
                .product(name: "TestHeartbeat", package: "swift-testing-heartbeat"),
            ],
            swiftSettings: [
                .define("SQLITE", .when(traits: ["SQLiteBackend"])),
                .define(
                    "DATABASE_SERVER_MULTIPLE_BASES",
                    .when(traits: ["MultipleBases"])
                ),
                .define(
                    "DATABASE_OPERATIONS_TEST_GRAPH_INDEXES",
                    .when(traits: ["GraphIndexes"])
                ),
                .define(
                    "DATABASE_OPERATIONS_TEST_VECTOR_INDEXES",
                    .when(traits: ["VectorIndexes"])
                ),
            ],
            linkerSettings: foundationDBClientLinkerSettings
        ),
        .target(
            name: "DatabaseServerFoundation",
            dependencies: [
                "DatabaseOperationCore",
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(
                    name: "DatabaseTypesFoundation",
                    package: "database-types"
                ),
            ]
        ),
        .target(
            name: "DatabaseServerHost",
            dependencies: [
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseRuntime", package: "database-framework"),
                "DatabaseServerRuntime",
                "DatabaseServerFoundation",
                .product(name: "StorageKit", package: "storage-kit"),
                .product(
                    name: "SQLiteStorage",
                    package: "storage-kit",
                    condition: .when(traits: ["SQLiteBackend"])
                ),
                .product(
                    name: "PostgreSQLStorage",
                    package: "storage-kit",
                    condition: .when(traits: ["PostgreSQLBackend"])
                ),
                .product(
                    name: "FDBStorage",
                    package: "storage-kit",
                    condition: .when(traits: ["FoundationDBBackend"])
                ),
                .product(
                    name: "FoundationDB",
                    package: "fdb-swift-bindings",
                    condition: .when(traits: ["FoundationDBBackend"])
                ),
                .product(name: "StorageKitSystemClock", package: "storage-kit"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdCore", package: "hummingbird"),
                .product(name: "HummingbirdTLS", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_SERVER_MULTIPLE_BASES",
                    .when(traits: ["MultipleBases"])
                ),
                .define(
                    "DATABASE_SERVER_HOST_MULTIPLE_BASES",
                    .when(traits: ["MultipleBases"])
                ),
                .define(
                    "DATABASE_SERVER_SQLITE_BACKEND",
                    .when(traits: ["SQLiteBackend"])
                ),
                .define(
                    "DATABASE_SERVER_POSTGRESQL_BACKEND",
                    .when(traits: ["PostgreSQLBackend"])
                ),
                .define(
                    "DATABASE_SERVER_FOUNDATIONDB_BACKEND",
                    .when(traits: ["FoundationDBBackend"])
                ),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L/usr/local/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/usr/local/lib",
                ]),
            ]
        ),
        .executableTarget(
            name: "DatabaseServer",
            dependencies: [
                "DatabaseServerHost",
                "DatabaseServerRuntime",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_SERVER_MULTIPLE_BASES",
                    .when(traits: ["MultipleBases"])
                ),
            ]
        ),
        .testTarget(
            name: "DatabaseServerHostTests",
            dependencies: [
                "DatabaseServerHost",
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseRuntime", package: "database-framework"),
                "DatabaseServerRuntime",
                "DatabaseServerFoundation",
                .product(name: "StorageKit", package: "storage-kit"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_SERVER_MULTIPLE_BASES",
                    .when(traits: ["MultipleBases"])
                ),
                .define(
                    "DATABASE_SERVER_HOST_MULTIPLE_BASES",
                    .when(traits: ["MultipleBases"])
                ),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
