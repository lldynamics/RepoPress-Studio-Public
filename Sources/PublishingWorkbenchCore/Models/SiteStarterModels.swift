import Foundation

public enum SiteStarterTemplateID: String, Codable, CaseIterable, Identifiable, Sendable {
  case zolaPersonalBlog
  case astroPersonalBlog
  case hugoPersonalBlog
  case vitePressDocumentation

  public var id: String { rawValue }

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    switch value {
    case Self.zolaPersonalBlog.rawValue, "zolaPortfolio", "hexoPersonalBlog", "jekyllPersonalBlog":
      // Retired portfolio, Hexo, and Jekyll starters migrate to the maintained
      // Zola starting point without reintroducing their dependency stacks.
      self = .zolaPersonalBlog
    case Self.astroPersonalBlog.rawValue:
      self = .astroPersonalBlog
    case Self.hugoPersonalBlog.rawValue:
      self = .hugoPersonalBlog
    case Self.vitePressDocumentation.rawValue:
      self = .vitePressDocumentation
    default:
      throw DecodingError.dataCorruptedError(
        in: try decoder.singleValueContainer(),
        debugDescription: "Unknown Site Starter template ID: \(value)"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct SiteStarterTemplatePreview: Codable, Hashable, Sendable {
  public var headline: String
  public var subtitle: String
  public var primarySectionTitle: String
  public var sampleItems: [String]
  public var accentName: String

  public init(
    headline: String,
    subtitle: String,
    primarySectionTitle: String,
    sampleItems: [String],
    accentName: String
  ) {
    self.headline = headline
    self.subtitle = subtitle
    self.primarySectionTitle = primarySectionTitle
    self.sampleItems = sampleItems
    self.accentName = accentName
  }
}

public struct SiteStarterTemplate: Identifiable, Codable, Hashable, Sendable {
  public var id: SiteStarterTemplateID
  public var name: String
  public var siteKind: SiteKind
  public var summary: String
  public var defaultTags: [String]
  public var defaultCategories: [String]
  public var preview: SiteStarterTemplatePreview

  public init(
    id: SiteStarterTemplateID,
    name: String,
    siteKind: SiteKind,
    summary: String,
    defaultTags: [String],
    defaultCategories: [String],
    preview: SiteStarterTemplatePreview
  ) {
    self.id = id
    self.name = name
    self.siteKind = siteKind
    self.summary = summary
    self.defaultTags = defaultTags
    self.defaultCategories = defaultCategories
    self.preview = preview
  }

  public static let builtIn: [SiteStarterTemplate] = [
    SiteStarterTemplate(
      id: .zolaPersonalBlog,
      name: CoreL10n.text("Zola 写作起点"),
      siteKind: .zola,
      summary: CoreL10n.text("一套可直接发布的 Zola 写作起点，包含文章、RSS、搜索和部署工作流。"),
      defaultTags: [CoreL10n.text("写作")],
      defaultCategories: ["Blog"],
      preview: SiteStarterTemplatePreview(
        headline: CoreL10n.text("最新文章优先"),
        subtitle: CoreL10n.text("清爽首页、文章列表、独立文章页，适合长期写作。"),
        primarySectionTitle: CoreL10n.text("最新文章"),
        sampleItems: [CoreL10n.text("欢迎文章"), CoreL10n.text("工程记录"), CoreL10n.text("读书笔记")],
        accentName: CoreL10n.text("蓝绿")
      )
    ),
    SiteStarterTemplate(
      id: .astroPersonalBlog,
      name: CoreL10n.text("Astro 博客"),
      siteKind: .astro,
      summary: CoreL10n.text("Astro 内容集合起点，适合轻量博客和后续组件化扩展。"),
      defaultTags: [CoreL10n.text("写作")],
      defaultCategories: ["Blog"],
      preview: SiteStarterTemplatePreview(
        headline: CoreL10n.text("组件化内容站"),
        subtitle: CoreL10n.text("Markdown/MDX 内容、简洁布局和前端扩展空间。"),
        primarySectionTitle: "Blog",
        sampleItems: [CoreL10n.text("MDX 文章"), CoreL10n.text("组件示例"), CoreL10n.text("静态页面")],
        accentName: CoreL10n.text("橙红")
      )
    ),
    SiteStarterTemplate(
      id: .hugoPersonalBlog,
      name: CoreL10n.text("Hugo 博客"),
      siteKind: .hugo,
      summary: CoreL10n.text("Hugo 写作起点，适合快速构建和大量 Markdown 内容。"),
      defaultTags: [CoreL10n.text("写作")],
      defaultCategories: ["Blog"],
      preview: SiteStarterTemplatePreview(
        headline: CoreL10n.text("高速静态博客"),
        subtitle: CoreL10n.text("内容目录清晰、构建快，适合文章量增长后的维护。"),
        primarySectionTitle: "Posts",
        sampleItems: [CoreL10n.text("第一篇文章"), CoreL10n.text("归档入口"), CoreL10n.text("标签页")],
        accentName: CoreL10n.text("青色")
      )
    ),
    SiteStarterTemplate(
      id: .vitePressDocumentation,
      name: CoreL10n.text("VitePress 文档站"),
      siteKind: .vitePress,
      summary: CoreL10n.text("VitePress 文档起点，适合产品手册、工程文档和知识库。"),
      defaultTags: [CoreL10n.text("文档")],
      defaultCategories: ["Docs"],
      preview: SiteStarterTemplatePreview(
        headline: CoreL10n.text("可搜索的文档站"),
        subtitle: CoreL10n.text("以 Markdown 为核心，自带导航、侧边栏和本地搜索。"),
        primarySectionTitle: CoreL10n.text("开始使用"),
        sampleItems: [CoreL10n.text("快速开始"), CoreL10n.text("使用指南"), CoreL10n.text("更新日志")],
        accentName: CoreL10n.text("青绿")
      )
    ),
  ]
}

public enum SiteStarterDeploymentTarget: String, Codable, CaseIterable, Identifiable, Sendable {
  case githubPages
  case netlify
  case vercel
  case cloudflarePages
  case none

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .githubPages:
      return "GitHub Pages"
    case .netlify:
      return "Netlify"
    case .vercel:
      return "Vercel"
    case .cloudflarePages:
      return "Cloudflare Pages"
    case .none:
      return "暂不部署"
    }
  }

  public var deploymentProvider: DeploymentProvider? {
    switch self {
    case .githubPages:
      return .githubPages
    case .netlify:
      return .netlify
    case .vercel:
      return .vercel
    case .cloudflarePages:
      return .cloudflarePages
    case .none:
      return nil
    }
  }
}

public struct SiteStarterRequest: Codable, Hashable, Sendable {
  public var templateID: SiteStarterTemplateID
  public var rootPath: String
  public var siteName: String
  public var siteDescription: String
  public var author: String
  public var baseURL: String
  public var branch: String
  public var githubOwner: String
  public var githubRepositoryName: String
  public var deploymentTarget: SiteStarterDeploymentTarget
  public var deploymentSiteURL: String
  public var deploymentProjectID: String
  public var deploymentAccountID: String
  public var initializeGit: Bool
  public var configureOriginRemote: Bool
  public var now: Date

  public init(
    templateID: SiteStarterTemplateID = .zolaPersonalBlog,
    rootPath: String,
    siteName: String,
    siteDescription: String = "",
    author: String = "",
    baseURL: String = "",
    branch: String = "main",
    githubOwner: String = "",
    githubRepositoryName: String = "",
    deploymentTarget: SiteStarterDeploymentTarget = .githubPages,
    deploymentSiteURL: String = "",
    deploymentProjectID: String = "",
    deploymentAccountID: String = "",
    initializeGit: Bool = true,
    configureOriginRemote: Bool = true,
    now: Date = Date()
  ) {
    self.templateID = templateID
    self.rootPath = rootPath
    self.siteName = siteName
    self.siteDescription = siteDescription
    self.author = author
    self.baseURL = baseURL
    self.branch = branch
    self.githubOwner = githubOwner
    self.githubRepositoryName = githubRepositoryName
    self.deploymentTarget = deploymentTarget
    self.deploymentSiteURL = deploymentSiteURL
    self.deploymentProjectID = deploymentProjectID
    self.deploymentAccountID = deploymentAccountID
    self.initializeGit = initializeGit
    self.configureOriginRemote = configureOriginRemote
    self.now = now
  }
}

public struct SiteStarterImportRequest: Codable, Hashable, Sendable {
  public var rootPath: String
  public var siteName: String
  public var siteKind: SiteKind
  public var author: String
  public var branch: String
  public var githubOwner: String
  public var githubRepositoryName: String
  public var deploymentTarget: SiteStarterDeploymentTarget
  public var deploymentSiteURL: String
  public var deploymentProjectID: String
  public var deploymentAccountID: String

  public init(
    rootPath: String,
    siteName: String,
    siteKind: SiteKind = .zola,
    author: String = "",
    branch: String = "main",
    githubOwner: String = "",
    githubRepositoryName: String = "",
    deploymentTarget: SiteStarterDeploymentTarget = .githubPages,
    deploymentSiteURL: String = "",
    deploymentProjectID: String = "",
    deploymentAccountID: String = ""
  ) {
    self.rootPath = rootPath
    self.siteName = siteName
    self.siteKind = siteKind
    self.author = author
    self.branch = branch
    self.githubOwner = githubOwner
    self.githubRepositoryName = githubRepositoryName
    self.deploymentTarget = deploymentTarget
    self.deploymentSiteURL = deploymentSiteURL
    self.deploymentProjectID = deploymentProjectID
    self.deploymentAccountID = deploymentAccountID
  }
}

public struct SiteStarterResult: Codable, Hashable, Sendable {
  public var profile: SiteProfile
  public var initialDraft: ArticleDraft
  public var createdFilePaths: [String]
  public var initializedGit: Bool
  public var configuredRemoteURL: String?
  public var deploymentGuidePath: String?
  public var nextCommands: [String]

  public init(
    profile: SiteProfile,
    initialDraft: ArticleDraft,
    createdFilePaths: [String],
    initializedGit: Bool,
    configuredRemoteURL: String?,
    deploymentGuidePath: String?,
    nextCommands: [String]
  ) {
    self.profile = profile
    self.initialDraft = initialDraft
    self.createdFilePaths = createdFilePaths
    self.initializedGit = initializedGit
    self.configuredRemoteURL = configuredRemoteURL
    self.deploymentGuidePath = deploymentGuidePath
    self.nextCommands = nextCommands
  }
}

public struct SiteStarterPushResult: Codable, Hashable, Sendable {
  public var rootPath: String
  public var branch: String
  public var remoteURL: String
  public var commitSHA: String
  public var committedPaths: [String]
  public var output: String

  public init(
    rootPath: String,
    branch: String,
    remoteURL: String,
    commitSHA: String,
    committedPaths: [String],
    output: String
  ) {
    self.rootPath = rootPath
    self.branch = branch
    self.remoteURL = remoteURL
    self.commitSHA = commitSHA
    self.committedPaths = committedPaths
    self.output = output
  }
}

public struct SiteStarterImportResult: Codable, Hashable, Sendable {
  public var profile: SiteProfile
  public var importedDraftCount: Int
  public var updatedDraftCount: Int
  public var skippedPathCount: Int
  public var isGitRepository: Bool
  public var detectedRemoteURL: String?
  public var nextCommands: [String]

  public init(
    profile: SiteProfile,
    importedDraftCount: Int,
    updatedDraftCount: Int,
    skippedPathCount: Int,
    isGitRepository: Bool,
    detectedRemoteURL: String?,
    nextCommands: [String]
  ) {
    self.profile = profile
    self.importedDraftCount = importedDraftCount
    self.updatedDraftCount = updatedDraftCount
    self.skippedPathCount = skippedPathCount
    self.isGitRepository = isGitRepository
    self.detectedRemoteURL = detectedRemoteURL
    self.nextCommands = nextCommands
  }
}
