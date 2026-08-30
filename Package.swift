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
    .library(
      name: "PublishingMCPClient",
      targets: ["PublishingMCPClient"]
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
    ),
    .package(
      url: "https://github.com/modelcontextprotocol/swift-sdk.git",
      exact: "0.12.1",
    ),
    .package(
      url: "https://github.com/apple/swift-system.git",
      from: "1.0.0"
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
        .linkedFramework("CoreML"),
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
    .target(
      name: "PublishingMCPClient",
      dependencies: [
        "PublishingAICore",
        "PublishingWorkbenchCore",
        .product(name: "MCP", package: "swift-sdk"),
        .product(name: "SystemPackage", package: "swift-system"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
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
        "PublishingGitCore",
        "PublishingKnowledgeCore",
        "PublishingWorkbenchCore",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .testTarget(
      name: "PublishingMCPClientTests",
      dependencies: [
        "PublishingAICore",
        "PublishingMCPClient",
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
        "PublishingGitCore",
        "PublishingMarkdownCore",
        "PublishingWorkbenchCore",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
  ]
)
