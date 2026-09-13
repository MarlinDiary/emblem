// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Emblem", platforms: [.macOS(.v14)],
    products: [.executable(name: "Emblem", targets: ["Emblem"]), .library(name: "PortraitCore", targets: ["PortraitCore"])],
    dependencies: [.package(url: "https://github.com/openid/AppAuth-iOS.git", exact: "3.0.0")],
    targets: [
        .target(name: "PortraitCore", resources: [.copy("Resources/public_suffix_list.dat"), .copy("Resources/claude-icon.svg")]),
        .target(name: "PortraitContactsBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("Contacts")]),
        .executableTarget(name: "Emblem", dependencies: ["PortraitCore", "PortraitContactsBridge", .product(name: "AppAuth", package: "AppAuth-iOS")]),
        .testTarget(name: "PortraitCoreTests", dependencies: ["PortraitCore"]),
        .testTarget(name: "EmblemTests", dependencies: ["Emblem"])
    ])
