import Foundation

public enum SiteStarterTemplateID: String, Codable, CaseIterable, Identifiable, Sendable {
  case zolaPersonalBlog
  case zolaPortfolio
  case astroPersonalBlog
  case hugoPersonalBlog
  case hexoPersonalBlog
  case jekyllPersonalBlog

  public var id: String { rawValue }
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
      name: "个人博客",
      siteKind: .zola,
      summary: "Zola 博客模板，适合写文章、随笔和技术记录。",
      defaultTags: ["写作"],
      defaultCategories: ["Blog"],
      preview: SiteStarterTemplatePreview(
        headline: "最新文章优先",
        subtitle: "清爽首页、文章列表、独立文章页，适合长期写作。",
        primarySectionTitle: "最新文章",
        sampleItems: ["欢迎文章", "工程记录", "读书笔记"],
        accentName: "蓝绿"
      )
    ),
    SiteStarterTemplate(
      id: .zolaPortfolio,
      name: "作品集",
      siteKind: .zola,
      summary: "Zola 作品集模板，首页突出个人介绍和项目入口。",
      defaultTags: ["作品"],
      defaultCategories: ["Portfolio"],
      preview: SiteStarterTemplatePreview(
        headline: "作品与记录",
        subtitle: "首页突出个人介绍、精选项目和后续文章入口。",
        primarySectionTitle: "精选项目",
        sampleItems: ["项目案例", "关于我", "近期记录"],
        accentName: "靛蓝"
      )
    ),
    SiteStarterTemplate(
      id: .astroPersonalBlog,
      name: "Astro 博客",
      siteKind: .astro,
      summary: "Astro 内容集合模板，适合轻量博客和后续组件化扩展。",
      defaultTags: ["写作"],
      defaultCategories: ["Blog"],
      preview: SiteStarterTemplatePreview(
        headline: "组件化内容站",
        subtitle: "Markdown/MDX 内容、简洁布局和前端扩展空间。",
        primarySectionTitle: "Blog",
        sampleItems: ["MDX 文章", "组件示例", "静态页面"],
        accentName: "橙红"
      )
    ),
    SiteStarterTemplate(
      id: .hugoPersonalBlog,
      name: "Hugo 博客",
      siteKind: .hugo,
      summary: "Hugo 博客模板，适合需要快速构建和传统内容目录的站点。",
      defaultTags: ["写作"],
      defaultCategories: ["Blog"],
      preview: SiteStarterTemplatePreview(
        headline: "高速静态博客",
        subtitle: "内容目录清晰、构建快，适合文章量增长后的维护。",
        primarySectionTitle: "Posts",
        sampleItems: ["第一篇文章", "归档入口", "标签页"],
        accentName: "青色"
      )
    ),
    SiteStarterTemplate(
      id: .hexoPersonalBlog,
      name: "Hexo 博客",
      siteKind: .hexo,
      summary: "Hexo 博客模板，适合 Node.js 生态和传统博客迁移。",
      defaultTags: ["写作"],
      defaultCategories: ["Blog"],
      preview: SiteStarterTemplatePreview(
        headline: "传统博客工作流",
        subtitle: "Source 目录、文章列表和 Hexo 构建脚本开箱可用。",
        primarySectionTitle: "Archives",
        sampleItems: ["Hello World", "分类", "归档"],
        accentName: "紫蓝"
      )
    ),
    SiteStarterTemplate(
      id: .jekyllPersonalBlog,
      name: "Jekyll 博客",
      siteKind: .jekyll,
      summary: "Jekyll 博客模板，适合 GitHub Pages 的传统 Markdown 工作流。",
      defaultTags: ["写作"],
      defaultCategories: ["Blog"],
      preview: SiteStarterTemplatePreview(
        headline: "GitHub Pages 友好",
        subtitle: "Jekyll 默认目录、Gemfile 和 Pages 工作流齐备。",
        primarySectionTitle: "Posts",
        sampleItems: ["欢迎文章", "页面模板", "日期归档"],
        accentName: "深灰"
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
