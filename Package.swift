// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GetMyIP",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GetMyIP",
            path: "Sources/GetMyIP",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-dead_strip"], .when(configuration: .release))]
        ),
        .testTarget(
            name: "GetMyIPTests",
            dependencies: ["GetMyIP"],
            path: "Tests/GetMyIPTests"
        )
    ]
)
