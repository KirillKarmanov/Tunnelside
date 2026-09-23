// swift-tools-version:5.9
// Сборка без Xcode: `swift build` собирает бинарники, `scripts/build-spm.sh` упаковывает их в Tunnelside.app.
import PackageDescription

let package = Package(
    name: "Tunnelside",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "RouteShared",
            path: "Sources/RouteShared"
        ),
        .target(
            name: "RouteHelperCore",
            dependencies: ["RouteShared"],
            path: "Sources/RouteHelperCore",
            linkerSettings: [.linkedFramework("SystemConfiguration")]
        ),
        .executableTarget(
            name: "TunnelsideHelper",
            dependencies: ["RouteShared", "RouteHelperCore"],
            path: "Sources/TunnelsideHelper",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "Tunnelside",
            dependencies: ["RouteShared", "RouteHelperCore"],
            path: "Sources/Tunnelside",
            exclude: ["Assets.xcassets", "AppIcon.icon", "Resources"]
        ),
        .testTarget(
            name: "RouteCoreTests",
            dependencies: ["RouteShared", "RouteHelperCore"],
            path: "Tests/RouteCoreTests"
        ),
    ]
)
