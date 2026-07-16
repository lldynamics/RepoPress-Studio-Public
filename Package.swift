// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "PersonalSitePublisherMac",
  defaultLocalization: "zh-Hans",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "PublishingWorkbenchCore",
      targets: ["PublishingWorkbenchCore"]
    ),
    .executable(
      name: "PersonalSitePublisherMac",
      targets: ["PersonalSitePublisherMac"]
    ),
  ],
  targets: [
    .target(
      name: "PublishingWorkbenchCore",
      resources: [
        .process("Resources")
      ]
    ),
    .target(
      name: "PublishingWorkbenchScreenshotSupport",
      dependencies: ["PublishingWorkbenchCore"]
    ),
    .executableTarget(
      name: "PersonalSitePublisherMac",
      dependencies: [
        "PublishingWorkbenchCore",
        "PublishingWorkbenchScreenshotSupport",
      ],
      exclude: [
        "AppStore.entitlements"
      ],
      resources: [
        .process("Resources")
      ]
    ),
    .testTarget(
      name: "PublishingWorkbenchCoreTests",
      dependencies: [
        "PublishingWorkbenchCore",
        "PublishingWorkbenchScreenshotSupport",
      ]
    ),
  ]
)
