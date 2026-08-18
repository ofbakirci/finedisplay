// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "finedisplay",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FineDisplayKit", targets: ["FineDisplayKit"]),
        .executable(name: "finedisplay", targets: ["finedisplay-cli"]),
        // Named differently from the CLI on purpose: SwiftPM writes both into .build/<config>/
        // and APFS is case-insensitive by default. The bundle script renames it to "FineDisplay".
        .executable(name: "FineDisplayApp", targets: ["FineDisplayApp"]),
    ],
    targets: [
        .target(
            name: "FineDisplayKit",
            path: "Sources/FineDisplayKit"
        ),
        .executableTarget(
            name: "finedisplay-cli",
            dependencies: ["FineDisplayKit"],
            path: "Sources/finedisplay-cli"
        ),
        .executableTarget(
            name: "FineDisplayApp",
            dependencies: ["FineDisplayKit"],
            path: "Sources/FineDisplayApp"
        ),
        .testTarget(
            name: "FineDisplayKitTests",
            dependencies: ["FineDisplayKit"],
            path: "Tests/FineDisplayKitTests"
        ),
    ]
)
