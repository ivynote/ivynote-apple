// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IvynoteKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "IvynoteKit", targets: ["IvynoteKit"]),
    ],
    targets: [
        .target(name: "IvynoteKit"),
        .testTarget(name: "IvynoteKitTests", dependencies: ["IvynoteKit"]),
    ]
)
