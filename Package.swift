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
    ],
    targets: [
        .target(
            name: "RemindersCore",
            linkerSettings: [
                .linkedFramework("EventKit"),
            ]
        ),
        .executableTarget(
            name: "reminders",
            dependencies: [
                "RemindersCore",
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
        .testTarget(
            name: "RemindersCoreTests",
            dependencies: ["RemindersCore"]
        ),
        .testTarget(
            name: "RemindersCLITests",
            dependencies: ["reminders"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
