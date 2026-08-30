// swift-tools-version: 6.0
import PackageDescription

// The scanning engine lives here, deliberately separate from the app target, so it
// can be built and tested headlessly with `swift test` — no Xcode, no signing, no UI.
let package = Package(
    name: "ScoloCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ScoloCore", targets: ["ScoloCore"]),
        .executable(name: "scolo-cli", targets: ["scolo-cli"])
    ],
    targets: [
        .target(
            name: "ScoloCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "scolo-cli",
            dependencies: ["ScoloCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ScoloCoreTests",
            dependencies: ["ScoloCore"],
            // Recorded `diskutil -plist` output, read directly from #filePath.
            exclude: ["Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
