// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Emblem", platforms: [.macOS(.v14)],
    products: [.executable(name: "Emblem", targets: ["Emblem"]), .library(name: "PortraitCore", targets: ["PortraitCore"])],
    dependencies: [.package(url: "https://github.com/openid/AppAuth-iOS.git", exact: "3.0.0"), .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"), .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9")],
    targets: [
        .target(name: "PortraitCore", dependencies: [.product(name:"SwiftSoup",package:"SwiftSoup")], resources: [.copy("Resources/public_suffix_list.dat"), .copy("Resources/claude-icon.svg")]),
        .target(name: "PortraitContactsBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("Contacts")]),
        .executableTarget(name: "Emblem", dependencies: ["PortraitCore", "PortraitContactsBridge", .product(name: "AppAuth", package: "AppAuth-iOS"), .product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]),
        .testTarget(name: "PortraitCoreTests", dependencies: ["PortraitCore"]),
        .testTarget(name: "EmblemTests", dependencies: ["Emblem"], resources: [.copy("Fixtures")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."])])
    ])
