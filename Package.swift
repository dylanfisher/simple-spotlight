// swift-tools-version: 6.2

import PackageDescription

let strict: [SwiftSetting] = [
    .unsafeFlags(["-warnings-as-errors"])
]

let package = Package(
    name: "SimpleSpotlight",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "Base", swiftSettings: strict),
        .target(name: "Search", dependencies: ["Base"], swiftSettings: strict),
        .target(name: "Interface", dependencies: ["Search", "Base"], swiftSettings: strict),
        .executableTarget(
            name: "SimpleSpotlight", dependencies: ["Interface", "Search", "Base"],
            exclude: ["Info.plist", "AppIcon.svg"],
            swiftSettings: strict),
        .testTarget(name: "BaseTests", dependencies: ["Base"], swiftSettings: strict),
        .testTarget(
            name: "SearchTests", dependencies: ["Search", "Base"], swiftSettings: strict),
        .testTarget(
            name: "InterfaceTests", dependencies: ["Interface", "Search"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
