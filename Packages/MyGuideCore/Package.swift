// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyGuideCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "MyGuideCore", targets: ["MyGuideCore"])
    ],
    targets: [
        .target(name: "MyGuideCore"),
        .testTarget(name: "MyGuideCoreTests", dependencies: ["MyGuideCore"])
    ]
)
