// swift-tools-version: 6.2

import PackageDescription

let strict: [SwiftSetting] = [
    .unsafeFlags(["-warnings-as-errors"])
]
// Tests run only on the build machine, which is newer than the deployment target, so they use
// newer APIs without availability checks (docs/decisions/0016-macos-12-branch.md).
let tests = strict + [.unsafeFlags(["-Xfrontend", "-disable-availability-checking"])]

let package = Package(
    name: "SimpleSpotlight",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "Base", swiftSettings: strict),
        .target(name: "Search", dependencies: ["Base"], swiftSettings: strict),
        .target(name: "Interface", dependencies: ["Search", "Base"], swiftSettings: strict),
        .executableTarget(
            name: "SimpleSpotlight", dependencies: ["Interface", "Search", "Base"],
            exclude: ["Info.plist"],
            swiftSettings: strict),
        .testTarget(name: "BaseTests", dependencies: ["Base"], swiftSettings: tests),
        .testTarget(
            name: "SearchTests", dependencies: ["Search", "Base"], swiftSettings: tests),
        .testTarget(
            name: "InterfaceTests", dependencies: ["Interface", "Search"], swiftSettings: tests),
    ],
    swiftLanguageModes: [.v6]
)
