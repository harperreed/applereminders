// swift-tools-version: 6.0
// ABOUTME: Swift package manifest for reminders-mcp.
// ABOUTME: Defines a CLI tool wrapping EventKit with MCP server support.
import PackageDescription

let package = Package(
    name: "reminders-mcp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "reminders", targets: ["reminders"]),
        .library(name: "RemindersCore", targets: ["RemindersCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "RemindersCore",
            linkerSettings: [
                .linkedFramework("EventKit"),
            ]
        ),
        .target(
            name: "RemindersServer",
            dependencies: [
                "RemindersCore",
                .product(name: "Hummingbird", package: "hummingbird"),
            ]
        ),
        .executableTarget(
            name: "reminders",
            dependencies: [
                "RemindersCore",
                "RemindersServer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/RemindersCLI",
            exclude: [
                "Resources/Info.plist",
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/RemindersCLI/Resources/Info.plist",
                ]),
            ]
        ),
        .target(
            name: "RemindersTestSupport",
            dependencies: ["RemindersCore"],
            path: "Tests/RemindersTestSupport"
        ),
        .testTarget(
            name: "RemindersCoreTests",
            dependencies: ["RemindersCore", "RemindersTestSupport"]
        ),
        .testTarget(
            name: "RemindersServerTests",
            dependencies: [
                "RemindersServer",
                "RemindersTestSupport",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]
        ),
        .testTarget(
            name: "RemindersCLITests",
            dependencies: ["reminders", "RemindersTestSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
