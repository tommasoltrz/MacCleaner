// swift-tools-version: 6.0
import PackageDescription

// The scanning engine lives here, deliberately separate from the app target, so it
// can be built and tested headlessly with `swift test` — no Xcode, no signing, no UI.
let package = Package(
    name: "MoppoCore",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "MoppoCore", targets: ["MoppoCore"]),
        .executable(name: "moppo-cli", targets: ["moppo-cli"])
    ],
    targets: [
        .target(
            name: "MoppoCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "moppo-cli",
            dependencies: ["MoppoCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MoppoCoreTests",
            dependencies: ["MoppoCore"],
            // Recorded `diskutil -plist` output, read directly from #filePath.
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
