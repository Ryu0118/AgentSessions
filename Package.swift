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
            ]
        ),
        .testTarget(
            name: "AgentSessionsTests",
            dependencies: ["AgentSessions"]
        ),
    ]
)
