// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "macos-websocket-proxy",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MacOSWebSocketProxy", targets: ["MacOSWebSocketProxy"]),
    ],
    targets: [
        .target(
            name: "ProxyCore",
            path: "Sources/ProxyCore"
        ),
        .executableTarget(
            name: "MacOSWebSocketProxy",
            dependencies: ["ProxyCore"],
            path: "Sources/MacOSWebSocketProxy"
        ),
        .testTarget(
            name: "ProxyCoreTests",
            dependencies: ["ProxyCore"],
            path: "Tests/ProxyCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
