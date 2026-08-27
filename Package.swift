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
      name: "PublishingMarkdownCore",
      targets: ["PublishingMarkdownCore"]
    ),
    .library(
      name: "PublishingGitCore",
      targets: ["PublishingGitCore"]
    ),
    .library(
      name: "PublishingAICore",
      targets: ["PublishingAICore"]
    ),
    .library(
      name: "PublishingKnowledgeCore",
      targets: ["PublishingKnowledgeCore"]
    ),
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
      url: "https://github.com/tree-sitter/swift-tree-sitter",
      exact: "0.25.0"
    ),
    .package(
      url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown",
      from: "0.5.3"
    ),
    .package(
      url: "https://github.com/sparkle-project/Sparkle",
      from: "2.9.2"
    )
  ],
  targets: [
    .target(
      name: "PublishingCoreSupport",
      resources: [
        .process("Resources")
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .target(
      name: "PublishingDomainContracts",
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .target(
      name: "PublishingMarkdownCore",
      dependencies: [
        "PublishingCoreSupport",
        .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
        .product(name: "SwiftTreeSitterLayer", package: "swift-tree-sitter"),
        .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .target(
      name: "PublishingGitCore",
      dependencies: [
        "PublishingCoreSupport",
        "PublishingDomainContracts",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .target(
      name: "PublishingAICore",
      dependencies: [
        "PublishingCoreSupport",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .target(
      name: "PublishingKnowledgeCore",
      dependencies: [
        "PublishingCoreSupport",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ],
      linkerSettings: [
        .linkedLibrary("z"),
        .linkedFramework("PDFKit"),
        .linkedFramework("Vision"),
      ]
    ),
    .target(
      name: "PublishingWorkbenchCore",
      dependencies: [
        "PublishingCoreSupport",
        "PublishingDomainContracts",
        "PublishingMarkdownCore",
        "PublishingGitCore",
        "PublishingAICore",
        "PublishingKnowledgeCore",
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
        "PublishingGitCore",
        "PublishingMarkdownCore",
        "PublishingWorkbenchCore",
        .product(name: "Sparkle", package: "Sparkle"),
      ],
      resources: [
        .process("Resources")
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .target(
      name: "BrowserExtensionProtocolSupport",
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .testTarget(
      name: "PublishingMarkdownCoreTests",
      dependencies: [
        "PublishingCoreSupport",
        "PublishingMarkdownCore",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .testTarget(
      name: "PublishingGitCoreTests",
      dependencies: [
        "PublishingGitCore",
        "PublishingDomainContracts",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .testTarget(
      name: "PublishingDomainContractsTests",
      dependencies: [
        "PublishingDomainContracts",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .testTarget(
      name: "PublishingAICoreTests",
      dependencies: [
        "PublishingAICore",
        "PublishingCoreSupport",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .testTarget(
      name: "PublishingCoreSupportTests",
      dependencies: [
        "PublishingCoreSupport",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .testTarget(
      name: "PublishingKnowledgeCoreTests",
      dependencies: [
        "PublishingKnowledgeCore",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .testTarget(
      name: "PublishingWorkbenchCoreTests",
      dependencies: [
        "BrowserExtensionProtocolSupport",
        "PublishingAICore",
        "PublishingWorkbenchCore",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .testTarget(
      name: "PersonalSitePublisherMacTests",
      dependencies: [
        "PersonalSitePublisherMac",
        "BrowserExtensionProtocolSupport",
        "PublishingMarkdownCore",
        "PublishingWorkbenchCore",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
  ]
)
