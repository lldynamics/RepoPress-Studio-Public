import Foundation
import PublishingDomainContracts

public struct SiteProfile: Codable, Hashable, Identifiable, Sendable {
  public static let defaultProfileID = UUID(
    uuid: (
      0xF4, 0x4F, 0x7D, 0xB7,
      0x8D, 0x6F,
      0x44, 0xA3,
      0xA4, 0xF3,
      0x1D, 0x0C, 0x05, 0x93, 0x1F, 0x31
    ))
  public static let privateContentRoot = "private"

  public var id: UUID
  public var name: String
  public var purpose: SiteProfilePurpose
  public var siteKind: SiteKind
  public var frontMatterStyle: FrontMatterStyle
  public var repositoryProvider: RepositoryProvider
  public var repositoryBaseURL: String
  public var localRepositoryRootPath: String
  public var repoOwner: String
  public var repoName: String
  public var branch: String
  public var repositoryPublishStrategy: RepositoryPublishStrategy
  public var contentRoot: String
  public var assetRoot: String
  public var markdownPathPattern: String
  /// Optional path template for linked translations. Hugo and Zola use a
  /// same-directory language suffix when this is absent.
  public var translationMarkdownPathPattern: String?
  public var imagePathPattern: String
  public var publicImagePathPattern: String
  public var dateFormat: String
  public var defaultAuthor: String
  public var defaultTags: [String]
  public var defaultCategories: [String]
  public var includeDraftFlagInFrontMatter: Bool
  public var includeCoverInFrontMatter: Bool
  public var slugValidationRule: SiteSlugValidationRule
  /// Whether this site should automatically add repository articles that are
  /// not yet represented in the writing library. Optional storage keeps older
  /// snapshots backward compatible; `nil` preserves the historical enabled
  /// behavior.
  public var automaticallyImportsNewRepositoryArticles: Bool?
  /// Whether the SEO audit should warn when a Markdown H1 repeats the Front
  /// Matter title. Optional storage keeps older snapshots backward compatible;
  /// `nil` follows the locally inspected theme when its title layout is known.
  /// An unknown theme preserves the historical enabled behavior.
  public var warnsWhenBodyH1DuplicatesTitle: Bool?
  /// Optional for snapshots created before external Markdown source mapping.
  public var externalDraftFolder: ExternalDraftFolderMapping?
  /// The reusable AI connection selected by this site. The legacy config is
  /// retained for decoding older workbench files and non-store clients.
  public var aiConnectionProfileID: UUID?
  public var aiProviderConfig: AIProviderConfig
  public var aiWritingStyle: AIWritingStyleConfig?
  public var deploymentProvider: DeploymentProvider?
  public var deploymentSiteURL: String?
  public var deploymentStatusEndpointURL: String?
  public var deploymentStatusEndpointUsesToken: Bool?
  public var deploymentProjectID: String?
  public var deploymentAccountID: String?
  /// Legacy reading analytics settings are preserved when older profiles are
  /// loaded and saved. Access tokens were never serialized in this profile.
  public var siteAnalytics: SiteAnalyticsSettings?

  public init(
    id: UUID = UUID(),
    name: String,
    purpose: SiteProfilePurpose = .publishing,
    siteKind: SiteKind = .zola,
    frontMatterStyle: FrontMatterStyle = .toml,
    repositoryProvider: RepositoryProvider = .github,
    repositoryBaseURL: String = RepositoryProvider.github.defaultBaseURL,
    localRepositoryRootPath: String = "",
    repoOwner: String = "",
    repoName: String = "",
    branch: String = "main",
    repositoryPublishStrategy: RepositoryPublishStrategy = .reviewRequest,
    contentRoot: String = "content",
    assetRoot: String = "static",
    markdownPathPattern: String = "content/posts/{year}/{slug}.md",
    translationMarkdownPathPattern: String? = nil,
    imagePathPattern: String = "static/images/{year}/{filename}",
    publicImagePathPattern: String = "/images/{year}/{filename}",
    dateFormat: String = "yyyy-MM-dd",
    defaultAuthor: String = "",
    defaultTags: [String] = [],
    defaultCategories: [String] = [],
    includeDraftFlagInFrontMatter: Bool = true,
    includeCoverInFrontMatter: Bool = true,
    slugValidationRule: SiteSlugValidationRule = .lowercaseKebab,
    automaticallyImportsNewRepositoryArticles: Bool? = true,
    warnsWhenBodyH1DuplicatesTitle: Bool? = nil,
    externalDraftFolder: ExternalDraftFolderMapping? = nil,
    aiConnectionProfileID: UUID? = nil,
    aiProviderConfig: AIProviderConfig = AIProviderConfig(
      advancedSettings: AIProviderAdvancedSettings(
        allowsApplicationTools: false
      )
    ),
    aiWritingStyle: AIWritingStyleConfig? = .default,
    deploymentProvider: DeploymentProvider? = nil,
    deploymentSiteURL: String? = nil,
    deploymentStatusEndpointURL: String? = nil,
    deploymentStatusEndpointUsesToken: Bool = false,
    deploymentProjectID: String? = nil,
    deploymentAccountID: String? = nil,
    siteAnalytics: SiteAnalyticsSettings? = nil
  ) {
    self.id = id
    self.name = name
    self.purpose = purpose
    self.siteKind = siteKind
    self.frontMatterStyle = frontMatterStyle
    self.repositoryProvider = repositoryProvider
    self.repositoryBaseURL = repositoryBaseURL
    self.localRepositoryRootPath = localRepositoryRootPath
    self.repoOwner = repoOwner
    self.repoName = repoName
    self.branch = branch
    self.repositoryPublishStrategy = repositoryPublishStrategy
    self.contentRoot = contentRoot
    self.assetRoot = assetRoot
    self.markdownPathPattern = markdownPathPattern
    self.translationMarkdownPathPattern = translationMarkdownPathPattern
    self.imagePathPattern = imagePathPattern
    self.publicImagePathPattern = publicImagePathPattern
    self.dateFormat = dateFormat
    self.defaultAuthor = defaultAuthor
    self.defaultTags = defaultTags
    self.defaultCategories = defaultCategories
    self.includeDraftFlagInFrontMatter = includeDraftFlagInFrontMatter
    self.includeCoverInFrontMatter = includeCoverInFrontMatter
    self.slugValidationRule = slugValidationRule
    self.automaticallyImportsNewRepositoryArticles = automaticallyImportsNewRepositoryArticles
    self.warnsWhenBodyH1DuplicatesTitle = warnsWhenBodyH1DuplicatesTitle
    self.externalDraftFolder = externalDraftFolder
    self.aiConnectionProfileID = aiConnectionProfileID
    self.aiProviderConfig = aiProviderConfig
    self.aiWritingStyle = aiWritingStyle
    self.deploymentProvider = deploymentProvider
    self.deploymentSiteURL = deploymentSiteURL
    self.deploymentStatusEndpointURL = deploymentStatusEndpointURL
    self.deploymentStatusEndpointUsesToken = deploymentStatusEndpointUsesToken
    self.deploymentProjectID = deploymentProjectID
    self.deploymentAccountID = deploymentAccountID
    self.siteAnalytics = siteAnalytics
  }

  public var resolvedAutomaticallyImportsNewRepositoryArticles: Bool {
    get { automaticallyImportsNewRepositoryArticles ?? true }
    set { automaticallyImportsNewRepositoryArticles = newValue }
  }

  public var resolvedAIWritingStyle: AIWritingStyleConfig {
    get { aiWritingStyle ?? .default }
    set { aiWritingStyle = newValue }
  }

  public var aiWritingStylePromptInstructions: String {
    let instructions = resolvedAIWritingStyle.promptInstructions
    return instructions.isEmpty ? "使用当前文章已有语气，保持克制、清楚、可发布。" : instructions
  }

  public static var defaultProfile: SiteProfile {
    var profile = SiteProfile(
      id: defaultProfileID,
      name: "个人网站",
      defaultAuthor: "Jinfang",
      defaultTags: ["写作", "工程"],
      defaultCategories: ["Blog"]
    )
    profile.applyPublishingDefaults(for: .zola)
    return profile
  }

  public static func defaultPublishingDefaults(for siteKind: SiteKind) -> SitePublishingDefaults {
    switch siteKind {
    case .zola:
      return SitePublishingDefaults(
        siteKind: .zola,
        frontMatterStyle: .toml,
        contentRoot: "content",
        assetRoot: "static",
        markdownPathPattern: "content/posts/{year}/{slug}.md",
        imagePathPattern: "static/images/{year}/{filename}",
        publicImagePathPattern: "/images/{year}/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .lowercaseKebab
      )
    case .astro:
      return SitePublishingDefaults(
        siteKind: .astro,
        frontMatterStyle: .yaml,
        contentRoot: "src/content/blog",
        assetRoot: "public",
        markdownPathPattern: "src/content/blog/{slug}.mdx",
        imagePathPattern: "public/images/{year}/{filename}",
        publicImagePathPattern: "/images/{year}/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .lowercaseKebab
      )
    case .hugo:
      return SitePublishingDefaults(
        siteKind: .hugo,
        frontMatterStyle: .yaml,
        contentRoot: "content",
        assetRoot: "static",
        markdownPathPattern: "content/posts/{slug}.md",
        imagePathPattern: "static/images/{year}/{filename}",
        publicImagePathPattern: "/images/{year}/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .lowercaseKebab
      )
    case .vitePress:
      return SitePublishingDefaults(
        siteKind: .vitePress,
        frontMatterStyle: .yaml,
        contentRoot: "docs/posts",
        assetRoot: "docs/public",
        markdownPathPattern: "docs/posts/{slug}.md",
        imagePathPattern: "docs/public/images/{year}/{filename}",
        publicImagePathPattern: "/images/{year}/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .lowercaseKebab
      )
    case .nextJS:
      return SitePublishingDefaults(
        siteKind: .nextJS,
        frontMatterStyle: .yaml,
        contentRoot: "content/posts",
        assetRoot: "public",
        markdownPathPattern: "content/posts/{slug}.mdx",
        imagePathPattern: "public/images/{year}/{filename}",
        publicImagePathPattern: "/images/{year}/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .lowercaseKebab
      )
    case .quartz:
      return SitePublishingDefaults(
        siteKind: .quartz,
        frontMatterStyle: .yaml,
        contentRoot: "content",
        assetRoot: "content",
        markdownPathPattern: "content/{slug}.md",
        imagePathPattern: "content/attachments/{filename}",
        publicImagePathPattern: "/attachments/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .relaxed
      )
    case .foam:
      return SitePublishingDefaults(
        siteKind: .foam,
        frontMatterStyle: .yaml,
        contentRoot: ".",
        assetRoot: "attachments",
        markdownPathPattern: "{slug}.md",
        imagePathPattern: "attachments/{filename}",
        publicImagePathPattern: "/attachments/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .relaxed
      )
    case .hexo:
      return SitePublishingDefaults(
        siteKind: .hexo,
        frontMatterStyle: .yaml,
        contentRoot: "source/_posts",
        assetRoot: "source",
        markdownPathPattern: "source/_posts/{slug}.md",
        imagePathPattern: "source/images/{year}/{filename}",
        publicImagePathPattern: "/images/{year}/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .lowercaseKebab
      )
    case .jekyll:
      return SitePublishingDefaults(
        siteKind: .jekyll,
        frontMatterStyle: .yaml,
        contentRoot: "_posts",
        assetRoot: "assets",
        markdownPathPattern: "_posts/{year}-{month}-{day}-{slug}.md",
        imagePathPattern: "assets/images/{year}/{filename}",
        publicImagePathPattern: "/assets/images/{year}/{filename}",
        dateFormat: "yyyy-MM-dd HH:mm:ss Z",
        includeDraftFlagInFrontMatter: false,
        includeCoverInFrontMatter: true,
        slugValidationRule: .lowercaseKebab
      )
    case .docusaurus:
      return SitePublishingDefaults(
        siteKind: .docusaurus,
        frontMatterStyle: .yaml,
        contentRoot: "docs",
        assetRoot: "static",
        markdownPathPattern: "docs/{slug}.md",
        imagePathPattern: "static/images/{year}/{filename}",
        publicImagePathPattern: "/images/{year}/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: true,
        includeCoverInFrontMatter: true,
        slugValidationRule: .lowercaseKebab
      )
    case .mkDocs:
      return SitePublishingDefaults(
        siteKind: .mkDocs,
        frontMatterStyle: .yaml,
        contentRoot: "docs",
        assetRoot: "docs",
        markdownPathPattern: "docs/{slug}.md",
        imagePathPattern: "docs/images/{year}/{filename}",
        publicImagePathPattern: "/images/{year}/{filename}",
        dateFormat: "yyyy-MM-dd",
        includeDraftFlagInFrontMatter: false,
        includeCoverInFrontMatter: false,
        slugValidationRule: .lowercaseKebab
      )
    }
  }

  /// Starlight is an Astro integration, so it keeps `.astro` as its persisted
  /// kind while using the integration's documented `src/content/docs` layout.
  public static var starlightPublishingDefaults: SitePublishingDefaults {
    SitePublishingDefaults(
      siteKind: .astro,
      frontMatterStyle: .yaml,
      contentRoot: "src/content/docs",
      assetRoot: "public",
      markdownPathPattern: "src/content/docs/{slug}.md",
      imagePathPattern: "public/images/{year}/{filename}",
      publicImagePathPattern: "/images/{year}/{filename}",
      dateFormat: "yyyy-MM-dd",
      includeDraftFlagInFrontMatter: true,
      includeCoverInFrontMatter: false,
      slugValidationRule: .lowercaseKebab
    )
  }

  public mutating func applyPublishingDefaults(for siteKind: SiteKind) {
    applyPublishingDefaults(Self.defaultPublishingDefaults(for: siteKind))
  }

  public mutating func applyPublishingDefaults(_ defaults: SitePublishingDefaults) {
    self.siteKind = defaults.siteKind
    frontMatterStyle = defaults.frontMatterStyle
    contentRoot = defaults.contentRoot
    assetRoot = defaults.assetRoot
    markdownPathPattern = defaults.markdownPathPattern
    imagePathPattern = defaults.imagePathPattern
    publicImagePathPattern = defaults.publicImagePathPattern
    dateFormat = defaults.dateFormat
    includeDraftFlagInFrontMatter = defaults.includeDraftFlagInFrontMatter
    includeCoverInFrontMatter = defaults.includeCoverInFrontMatter
    slugValidationRule = defaults.slugValidationRule
  }

  public var localRepositoryRootURL: URL? {
    resolvedLocalRepositoryRootURL
  }

  public var resolvedLocalRepositoryRootURL: URL? {
    let trimmed = localRepositoryRootPath.trimmedForPublishing
    guard !trimmed.isEmpty else { return nil }
    return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
  }

  public var repositoryDisplayName: String {
    let owner = repoOwner.trimmedForPublishing
    let repo = repoName.trimmedForPublishing
    guard !owner.isEmpty || !repo.isEmpty else {
      return repositoryProvider.displayName
    }
    return [owner, repo].filter { !$0.isEmpty }.joined(separator: "/")
  }

  @discardableResult
  public mutating func rememberLocalRepositoryRoot(_ url: URL) -> Bool {
    localRepositoryRootPath = url.standardizedFileURL.path
    return true
  }

  public func withLocalRepositoryRootAccess<T>(_ operation: (URL) throws -> T) rethrows -> T? {
    guard let rootURL = resolvedLocalRepositoryRootURL else {
      return nil
    }
    return try operation(rootURL)
  }

}
