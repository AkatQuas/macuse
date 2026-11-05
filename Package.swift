// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MacUse",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "MacUse", swiftSettings: [.swiftLanguageMode(.v5)])]
)
