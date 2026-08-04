import Foundation

public enum SiteStarterTemplateID: String, Codable, CaseIterable, Identifiable, Sendable {
  case zolaPersonalBlog

  public var id: String { rawValue }

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer().decode(String.self)
    switch value {
    case Self.zolaPersonalBlog.rawValue,
      "zolaPortfolio",
      "astroPersonalBlog",
      "hugoPersonalBlog",
      "hexoPersonalBlog",
      "jekyllPersonalBlog":
      // Older requests selected one of six built-in variants. They now all
      // resolve to the single maintained Zola starting point.
      self = .zolaPersonalBlog
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
