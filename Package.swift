// swift-tools-version:5.9
import PackageDescription

// Same Core → System → App split as AppClean and MacClean; Apple frameworks only.
let package = Package(
    name: "MacClipBoard",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MacClipBoardCore"),
        .target(name: "MacClipBoardSystem", dependencies: ["MacClipBoardCore"]),
        .executableTarget(name: "MacClipBoard", dependencies: ["MacClipBoardCore", "MacClipBoardSystem"]),
        // Synthetic editor for manual end-to-end verification; never included in the app bundle.
        .executableTarget(name: "clipboard-fixture"),
        .testTarget(name: "MacClipBoardTests", dependencies: ["MacClipBoardCore", "MacClipBoardSystem"]),
    ],
    swiftLanguageVersions: [.v5]
)
