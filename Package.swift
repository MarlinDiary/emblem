// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MailPortrait", platforms: [.macOS(.v14)],
    products: [.executable(name: "MailPortrait", targets: ["MailPortrait"]), .library(name: "PortraitCore", targets: ["PortraitCore"])],
    dependencies: [.package(url: "https://github.com/openid/AppAuth-iOS.git", exact: "3.0.0")],
    targets: [
        .target(name: "PortraitCore", resources: [.copy("Resources/public_suffix_list.dat"), .copy("Resources/claude-icon.svg")]),
        .target(name: "PortraitContactsBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("Contacts")]),
        .executableTarget(name: "MailPortrait", dependencies: ["PortraitCore", "PortraitContactsBridge", .product(name: "AppAuth", package: "AppAuth-iOS")]),
        .testTarget(name: "PortraitCoreTests", dependencies: ["PortraitCore"]),
        .testTarget(name: "MailPortraitTests", dependencies: ["MailPortrait"])
    ])
