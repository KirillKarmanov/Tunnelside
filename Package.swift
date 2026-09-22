// swift-tools-version:5.9
// Сборка без Xcode: `swift build` собирает бинарники, `scripts/build-spm.sh` упаковывает их в MacOSRoute.app.
import PackageDescription

let package = Package(
    name: "MacOSRoute",
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
            name: "MacOSRouteHelper",
            dependencies: ["RouteShared", "RouteHelperCore"],
            path: "Sources/MacOSRouteHelper",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "MacOSRoute",
            dependencies: ["RouteShared", "RouteHelperCore"],
            path: "Sources/MacOSRoute",
            exclude: ["Assets.xcassets", "AppIcon.icon", "Resources"]
        ),
        .testTarget(
            name: "RouteCoreTests",
            dependencies: ["RouteShared", "RouteHelperCore"],
            path: "Tests/RouteCoreTests"
        ),
    ]
)
