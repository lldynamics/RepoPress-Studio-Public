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
    .executable(
      name: "KnowledgeNativeMessagingHost",
      targets: ["KnowledgeNativeMessagingHost"]
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
        "KnowledgeNativeMessagingSupport",
        "PublishingWorkbenchCore",
      ],
      exclude: [
        "AppStore.entitlements"
      ],
      resources: [
        .process("Resources")
      ]
    ),
    .target(
      name: "KnowledgeNativeMessagingSupport"
    ),
    .executableTarget(
      name: "KnowledgeNativeMessagingHost",
      dependencies: [
        "KnowledgeNativeMessagingSupport",
      ]
    ),
    .testTarget(
      name: "PublishingWorkbenchCoreTests",
      dependencies: [
        "KnowledgeNativeMessagingSupport",
        "PublishingWorkbenchCore",
      ]
    ),
    .testTarget(
      name: "PersonalSitePublisherMacTests",
      dependencies: [
        "PersonalSitePublisherMac",
        "PublishingWorkbenchCore",
      ]
    ),
  ]
)
