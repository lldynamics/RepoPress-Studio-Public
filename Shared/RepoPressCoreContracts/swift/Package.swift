// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "RepoPressCore",
  platforms: [
    .iOS(.v17),
    .macOS(.v13)
  ],
  products: [
    .library(
      name: "RepoPressCore",
      targets: ["RepoPressCore"]
    )
  ],
  targets: [
    .target(
      name: "RepoPressCore",
      path: "Sources/RepoPressCore"
    ),
    .testTarget(
      name: "RepoPressCoreTests",
      dependencies: ["RepoPressCore"],
      path: "Tests/RepoPressCoreTests"
    )
  ],
  swiftLanguageModes: [.v6]
)
