// swift-tools-version:6.0
import PackageDescription

// A client for core's parking example (examples/dto-parking). core/ holds
// that example's exports, vendored at core/CORE_REV. The DTOs in
// Sources/ParkingContracts are generated from core/schemas with
// `tribrach-swift gen` (see generate.sh); the tests check them against
// Lean's verdicts and replay the exchanges core recorded.
let package = Package(
    name: "ParkingCLI",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "ParkingContracts", targets: ["ParkingContracts"]),
        .library(name: "ParkClient", targets: ["ParkClient"]),
        .executable(name: "park", targets: ["park"]),
    ],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(name: "ParkingContracts", dependencies: [.product(name: "TribrachWire", package: "tribrach-swift")]),
        .target(name: "ParkClient", dependencies: ["ParkingContracts", .product(name: "TribrachWire", package: "tribrach-swift")]),
        .executableTarget(name: "park", dependencies: ["ParkClient"]),
        .testTarget(
            name: "ParkingTests",
            dependencies: ["ParkingContracts", "ParkClient", .product(name: "TribrachWire", package: "tribrach-swift")]
        ),
    ]
)
