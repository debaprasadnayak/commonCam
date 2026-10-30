// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CommonCamKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CommonCamKit", targets: ["CommonCamKit"])],
    targets: [
        .target(name: "CommonCamKit"),
        .testTarget(name: "CommonCamKitTests", dependencies: ["CommonCamKit"]),
    ]
)
