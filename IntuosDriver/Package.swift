// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IntuosDriver",
    platforms: [
        // Plan targets macOS 26; keep 14 as SPM floor so tooling builds on older SDKs.
        // Runtime feature set is validated on macOS 26 Apple Silicon.
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "IntuosDriverCore",
            targets: ["IntuosDriverCore"]
        ),
        .executable(
            name: "intuos-cli",
            targets: ["IntuosDriverCLI"]
        ),
        .executable(
            name: "intuos-tests",
            targets: ["IntuosDriverTestRunner"]
        ),
        .executable(
            name: "IntuosDriverApp",
            targets: ["IntuosDriverApp"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(name: "intuos-pointer-tests", dependencies: ["IntuosDriverCore"], path: "Tests/IntuosDriverCoreTests"),
        .target(
            name: "IntuosDriverCore",
            dependencies: [],
            path: "Sources/IntuosDriverCore"
        ),
        .executableTarget(
            name: "IntuosDriverCLI",
            dependencies: ["IntuosDriverCore"],
            path: "Sources/IntuosDriverCLI"
        ),
        .executableTarget(
            name: "IntuosDriverTestRunner",
            dependencies: ["IntuosDriverCore"],
            path: "Sources/IntuosDriverTestRunner"
        ),
        .executableTarget(
            name: "IntuosDriverApp",
            dependencies: ["IntuosDriverCore"],
            path: "Sources/IntuosDriverApp"
        )
    ]
)
