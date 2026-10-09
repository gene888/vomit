// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StageCue",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "StageCue", targets: ["StageCue"])],
    targets: [.executableTarget(name: "StageCue", path: "Sources/StageCue")]
)
