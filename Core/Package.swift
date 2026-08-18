// swift-tools-version: 6.0
import PackageDescription

// The scanning engine lives here, deliberately separate from the app target, so it
// can be built and tested headlessly with `swift test` — no Xcode, no signing, no UI.
let package = Package(
    name: "MacCleanerCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MacCleanerCore", targets: ["MacCleanerCore"]),
        .executable(name: "maccleaner-cli", targets: ["maccleaner-cli"])
    ],
    targets: [
        .target(
            name: "MacCleanerCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "maccleaner-cli",
            dependencies: ["MacCleanerCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MacCleanerCoreTests",
            dependencies: ["MacCleanerCore"],
            // Recorded `diskutil -plist` output, read directly from #filePath.
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
