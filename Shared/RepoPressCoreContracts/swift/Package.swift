// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "RepoPressCore",
  platforms: [.iOS(.v17), .macOS(.v13)],
  products: [
    .library(name: "RepoPressCore", targets: ["RepoPressCore"]),
    .library(name: "RepoPressAppleSupport", targets: ["RepoPressAppleSupport"]),
  ],
  targets: [
    .target(name: "RepoPressCore"),
    .target(name: "RepoPressAppleSupport", dependencies: ["RepoPressCore"]),
    .testTarget(name: "RepoPressCoreTests", dependencies: ["RepoPressCore"]),
    .testTarget(
      name: "RepoPressAppleSupportTests", dependencies: ["RepoPressAppleSupport"],
      resources: [.copy("Fixtures")]
    ),
  ],
  swiftLanguageModes: [.v6]
)
