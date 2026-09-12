// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "MailPortrait", platforms: [.macOS(.v14)], products: [.library(name: "PortraitCore", targets: ["PortraitCore"])], targets: [.target(name: "PortraitCore"), .testTarget(name: "PortraitCoreTests", dependencies: ["PortraitCore"])])
