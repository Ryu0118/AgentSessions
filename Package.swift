// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentSessions",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "AgentSessions", targets: ["AgentSessions"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mtj0928/swift-async-operations.git", from: "0.5.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            providers: [
                .apt(["libsqlite3-dev"]),
            ]
        ),
        .target(
            name: "AgentSessions",
            dependencies: [
                "CSQLite",
                .product(name: "AsyncOperations", package: "swift-async-operations"),
            ]
        ),
        .testTarget(
            name: "AgentSessionsTests",
            dependencies: ["AgentSessions"]
        ),
    ]
)
