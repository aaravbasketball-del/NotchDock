// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchDock",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "NotchDock", targets: ["NotchDock"])],
    targets: [.executableTarget(name: "NotchDock")]
)
