// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PasteDeck",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PasteDeckCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "PasteDeck",
            dependencies: ["PasteDeckCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Command Line Tools ship neither XCTest nor swift-testing, so the
        // suite is a plain executable: `swift run CoreTests` / `make test`.
        .executableTarget(
            name: "CoreTests",
            dependencies: ["PasteDeckCore"],
            path: "Tests/CoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
