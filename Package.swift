// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "tribrach-swift",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "TribrachReplay", targets: ["TribrachReplay"]),
    ],
    targets: [
        .target(name: "TribrachReplay"),
    ]
)
