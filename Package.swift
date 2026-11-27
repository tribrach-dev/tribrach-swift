// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "tribrach-swift",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "TribrachCore", targets: ["TribrachCore"]),
        .library(name: "TribrachReplay", targets: ["TribrachReplay"]),
        .library(name: "TribrachWire", targets: ["TribrachWire"]),
        .executable(name: "tribrach-swift", targets: ["tribrach-swift"]),
        .plugin(name: "TribrachCheck", targets: ["TribrachCheck"]),
        .plugin(name: "TribrachStamp", targets: ["TribrachStamp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.1"),
    ],
    targets: [
        // Formats, the annotation grammar, drift and JSON equality. No dependencies.
        .target(name: "TribrachCore"),
        // The runtime for generated DTOs: reads JSON as core's Lean decoders do.
        // No dependencies.
        .target(name: "TribrachWire"),
        // Swift DTOs from the JSON Schemas core exports.
        .target(name: "TribrachGen", dependencies: ["TribrachWire"]),
        // Replay of exported vectors against a Swift implementation.
        .target(name: "TribrachReplay", dependencies: ["TribrachCore"]),
        // Reading Swift source: links, stamps and purity.
        .target(
            name: "TribrachSyntax",
            dependencies: [
                "TribrachCore",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
            ]
        ),
        .executableTarget(name: "tribrach-swift", dependencies: ["TribrachCore", "TribrachSyntax", "TribrachGen"]),
        .plugin(
            name: "TribrachCheck",
            capability: .buildTool(),
            dependencies: ["tribrach-swift"]
        ),
        .plugin(
            name: "TribrachStamp",
            capability: .command(
                intent: .custom(verb: "tribrach-stamp", description: "Record the manifest's Lean stamps next to linked functions"),
                permissions: [.writeToPackageDirectory(reason: "Writes //tribrach:stamp lines under //tribrach:link annotations")]
            ),
            dependencies: ["tribrach-swift"]
        ),
        .testTarget(
            name: "TribrachCoreTests",
            dependencies: ["TribrachCore", "TribrachReplay", "TribrachWire", "TribrachGen"],
            exclude: ["CORE_REV"],
            resources: [.copy("core")]
        ),
        .testTarget(name: "TribrachSyntaxTests", dependencies: ["TribrachSyntax", "TribrachCore"]),
    ]
)
