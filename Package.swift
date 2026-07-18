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
      ],
      linkerSettings: [
        .linkedLibrary("sqlite3"),
        .linkedLibrary("z"),
        .linkedFramework("PDFKit"),
        .linkedFramework("Vision"),
      ]
    ),
    .executableTarget(
      name: "PersonalSitePublisherMac",
      dependencies: [
        "PublishingWorkbenchCore",
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
      ]
    ),
  ]
)
