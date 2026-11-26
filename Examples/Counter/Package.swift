// swift-tools-version:6.0
import PackageDescription

// The bounded counter from the Tribrach core example. tribrach.manifest.json
// and Tests/CounterTests/counter.vectors.json are that example's exported
// files. The TribrachCheck plugin checks links, purity and drift on every
// build; `swift package tribrach-stamp` records stamps.
let package = Package(
    name: "Counter",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(
            name: "Counter",
            plugins: [.plugin(name: "TribrachCheck", package: "tribrach-swift")]
        ),
        .testTarget(
            name: "CounterTests",
            dependencies: ["Counter", .product(name: "TribrachReplay", package: "tribrach-swift")],
            resources: [.copy("counter.vectors.json")]
        ),
    ]
)
