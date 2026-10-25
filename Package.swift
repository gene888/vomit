// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StageCue",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "StageCue", targets: ["StageCue"])],
    targets: [
        .executableTarget(name: "StageCue", path: "Sources/StageCue", exclude: ["Info.plist"]),
        .testTarget(name: "StageCueTests", dependencies: ["StageCue"])
    ],
    swiftLanguageModes: [.v5]
)
