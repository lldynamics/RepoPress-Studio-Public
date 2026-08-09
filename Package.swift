// swift-tools-version: 6.0

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
  dependencies: [
    .package(
      url: "https://github.com/sparkle-project/Sparkle",
      from: "2.9.2"
    )
  ],
  targets: [
    .target(
      name: "PublishingWorkbenchCore",
      resources: [
        .process("Resources")
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
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
        "BrowserExtensionProtocolSupport",
        "PublishingWorkbenchCore",
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      exclude: [
        "AppStore.entitlements"
      ],
      resources: [
        .process("Resources")
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .target(
      name: "BrowserExtensionProtocolSupport",
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "PublishingWorkbenchCoreTests",
      dependencies: [
        "BrowserExtensionProtocolSupport",
        "PublishingWorkbenchCore",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
    .testTarget(
      name: "PersonalSitePublisherMacTests",
      dependencies: [
        "PersonalSitePublisherMac",
        "PublishingWorkbenchCore",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v5)
      ]
    ),
  ]
)
