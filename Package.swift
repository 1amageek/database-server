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
        name: "MultipleBases",
        condition: .when(traits: ["MultipleBases"])
    ),
])

let package = Package(
    name: "database-server",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "DatabaseServerHost",
            targets: ["DatabaseServerHost"]
        ),
        .executable(
            name: "database-server",
            targets: ["DatabaseServerExecutable"]
        ),
    ],
    traits: runtimeTraits,
    dependencies: [
        .package(
            url: "https://github.com/1amageek/database-framework.git",
            from: "26.0812.0",
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
            from: "26.0811.0"
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
    ],
    targets: [
        .target(
            name: "DatabaseServerHost",
            dependencies: [
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseTypes", package: "database-types"),
                .product(name: "DatabaseEngine", package: "database-framework"),
                .product(name: "DatabaseRuntime", package: "database-framework"),
                .product(name: "DatabaseWireRuntime", package: "database-framework"),
                .product(name: "DatabaseFoundation", package: "database-framework"),
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
            name: "DatabaseServerExecutable",
            dependencies: [
                "DatabaseServerHost",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "DatabaseKit", package: "database-kit"),
                .product(name: "DatabaseWire", package: "database-kit"),
                .product(name: "DatabaseWireRuntime", package: "database-framework"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_SERVER_EXECUTABLE_MULTIPLE_BASES",
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
                .product(name: "DatabaseWireRuntime", package: "database-framework"),
                .product(name: "DatabaseFoundation", package: "database-framework"),
                .product(name: "StorageKit", package: "storage-kit"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            swiftSettings: [
                .define(
                    "DATABASE_SERVER_HOST_MULTIPLE_BASES",
                    .when(traits: ["MultipleBases"])
                ),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
