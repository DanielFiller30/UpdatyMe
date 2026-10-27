// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "UpdatyMeCore",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .library(name: "UpdatyMeCore", targets: ["UpdatyMeCore"]),
        .library(name: "UpdatyMeCoreTestSupport", targets: ["UpdatyMeCoreTestSupport"]),
    ],
    targets: [
        .target(name: "UpdatyMeCore"),
        .target(
            name: "UpdatyMeCoreTestSupport",
            dependencies: ["UpdatyMeCore"]
        ),
        .testTarget(
            name: "UpdatyMeCoreTests",
            dependencies: ["UpdatyMeCore", "UpdatyMeCoreTestSupport"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
