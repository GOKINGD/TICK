// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TICK",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TICK", targets: ["TICK"]),
        .executable(name: "TICKObserver", targets: ["TICKObserver"])
    ],
    targets: [
        .executableTarget(
            name: "TICK",
            path: "Sources/TICK"
        ),
        .executableTarget(
            name: "TICKObserver",
            path: "Sources/TICKObserver"
        )
    ]
)
