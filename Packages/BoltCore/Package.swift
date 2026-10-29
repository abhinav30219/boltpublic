// swift-tools-version: 5.9
import PackageDescription
let package = Package(
  name: "BoltCore",
  platforms: [.iOS(.v16), .macOS(.v13)],
  products: [.library(name: "BoltCore", targets: ["BoltCore"])],
  targets: [
    .target(name: "BoltCore", path: "Sources/BoltCore"),
    .testTarget(name: "BoltCoreTests", dependencies: ["BoltCore"], path: "Tests/BoltCoreTests"),
  ]
)
