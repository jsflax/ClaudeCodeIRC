// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "ClaudeCodeIRC",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "claudecodeirc", targets: ["ClaudeCodeIRC"]),
        .library(name: "ClaudeCodeIRCCore", targets: ["ClaudeCodeIRCCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jsflax/NCursesUI.git", branch: "add-term-bell"),
        .package(url: "https://github.com/jsflax/lattice.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeCodeIRC",
            dependencies: [
                "ClaudeCodeIRCCore",
                .product(name: "NCursesUI", package: "NCursesUI"),
                .product(name: "Lattice", package: "lattice"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .target(
            name: "ClaudeCodeIRCCore",
            dependencies: [
                .product(name: "Lattice", package: "lattice"),
                .product(name: "NCursesUI", package: "NCursesUI"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .testTarget(
            name: "ClaudeCodeIRCCoreTests",
            dependencies: [
                "ClaudeCodeIRCCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        .testTarget(
            name: "ClaudeCodeIRCE2ETests",
            dependencies: [
                "ClaudeCodeIRC",  // executable — depending on it triggers the build
                "ClaudeCodeIRCCore",  // schema types (Member, Turn, AskQuestion) + RoomStore.schema
                .product(name: "NCUITest", package: "NCursesUI"),
                .product(name: "NCUITestProtocol", package: "NCursesUI"),
                .product(name: "Lattice", package: "lattice"),
            ],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ]
)
