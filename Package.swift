// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Shunt",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Shunt", targets: ["Shunt"]),
        .executable(name: "ShuntProxy", targets: ["ShuntProxy"]),
        .executable(name: "ShuntTest", targets: ["ShuntTest"]),
    ],
    targets: [
        .target(
            name: "ShuntCore",
            path: "Sources/ShuntCore"
        ),
        .executableTarget(
            name: "Shunt",
            dependencies: ["ShuntCore"],
            path: "Sources/Shunt"
        ),
        .executableTarget(
            name: "ShuntProxy",
            dependencies: ["ShuntCore"],
            path: "Sources/ShuntProxy",
            linkerSettings: [
                .linkedFramework("NetworkExtension"),
            ]
        ),
        .executableTarget(
            name: "ShuntTest",
            path: "Sources/ShuntTest"
        ),
    ]
)
