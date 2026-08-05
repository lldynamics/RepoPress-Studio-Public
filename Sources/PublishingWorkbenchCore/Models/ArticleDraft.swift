import CryptoKit
import Foundation

public enum DraftStatus: String, Codable, CaseIterable, Identifiable, Sendable {
  case draft
  case ready
  case published
  case failed

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .draft:
      return "草稿"
    case .ready:
      return "待发布"
    case .published:
      return "已发布"
    case .failed:
      return "失败"
    }
  }

  public var systemImage: String {
    switch self {
    case .draft:
      return "square.and.pencil"
    case .ready:
      return "paperplane"
    case .published:
      return "checkmark.seal"
    case .failed:
      return "xmark.octagon"
    }
  }
}

public enum ArticleVisibility: String, Codable, CaseIterable, Identifiable, Sendable {
  case `public`
  case `private`

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .public:
      return "公开"
    case .private:
      return "私密"
    }
  }

  public var systemImage: String {
    switch self {
    case .public:
      return "globe"
    case .private:
      return "lock"
    }
  }
}

public enum ArticleDraftScope: Codable, Hashable, Sendable {
  case site(UUID)
  case general

  public var siteProfileID: UUID? {
    guard case let .site(profileID) = self else { return nil }
    return profileID
  }

  public var isGeneral: Bool {
    self == .general
  }
}

public enum DraftListContentScope: String, Codable, CaseIterable, Identifiable, Sendable {
  case currentSite
  case general

  public var id: String { rawValue }
}

public struct DraftAttachment: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var originalFilename: String
  public var relativePublishPath: String
  public var repositoryPath: String
  public var altText: String
  public var caption: String
  public var byteSize: Int64
  public var sourceFilePath: String?
  public var repositorySHA: String?
  /// The object key and public CDN URL are optional so existing local-repository
  /// attachments remain fully backward compatible.
  public var remoteObjectKey: String?
  public var remoteURL: String?
  public var remoteETag: String?

  public init(
    id: UUID = UUID(),
    originalFilename: String,
    relativePublishPath: String,
    repositoryPath: String,
    altText: String = "",
    caption: String = "",
    byteSize: Int64 = 0,
    sourceFilePath: String? = nil,
    repositorySHA: String? = nil,
    remoteObjectKey: String? = nil,
    remoteURL: String? = nil,
    remoteETag: String? = nil
  ) {
    self.id = id
    self.originalFilename = originalFilename
    self.relativePublishPath = relativePublishPath
    self.repositoryPath = repositoryPath
    self.altText = altText
    self.caption = caption
    self.byteSize = byteSize
    self.sourceFilePath = sourceFilePath
    self.repositorySHA = repositorySHA
    self.remoteObjectKey = remoteObjectKey
    self.remoteURL = remoteURL
    self.remoteETag = remoteETag
  }
}

public struct GeneralDraftReuseSourceSnapshot: Codable, Hashable, Sendable {
  public var draftID: UUID
  public var sourceProfileName: String
  public var repositoryPath: String?
  public var title: String
  public var slug: String
  public var summary: String
  public var tags: [String]
  public var categories: [String]
  public var draft: Bool
  public var status: DraftStatus
  public var bodyMarkdown: String
  public var capturedAt: Date

  public init(
    draftID: UUID,
    sourceProfileName: String,
    repositoryPath: String?,
    title: String,
    slug: String,
    summary: String,
    tags: [String],
    categories: [String],
    draft: Bool,
    status: DraftStatus,
    bodyMarkdown: String,
    capturedAt: Date = Date()
  ) {
    self.draftID = draftID
    self.sourceProfileName = sourceProfileName
    self.repositoryPath = repositoryPath
    self.title = title
    self.slug = slug
    self.summary = summary
    self.tags = tags
    self.categories = categories
    self.draft = draft
    self.status = status
    self.bodyMarkdown = bodyMarkdown
    self.capturedAt = capturedAt
  }

  public static func make(from draft: ArticleDraft, sourceProfileName: String) -> GeneralDraftReuseSourceSnapshot {
    GeneralDraftReuseSourceSnapshot(
      draftID: draft.id,
      sourceProfileName: sourceProfileName,
      repositoryPath: draft.repositoryPath,
      title: draft.title,
      slug: draft.slug,
      summary: draft.summary,
      tags: draft.tags,
      categories: draft.categories,
      draft: draft.draft,
      status: draft.status,
      bodyMarkdown: draft.bodyMarkdown
    )
  }
}

public struct ArticleDraft: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  /// The site used for site-owned drafts and as an editing context for general drafts.
  /// Ownership must be read through `scope` rather than inferred from this value.
  public private(set) var siteProfileID: UUID
  /// Optional storage keeps snapshots written before draft scopes backward compatible.
  /// Legacy drafts resolve to their existing site and are normalized on load.
  private var scopeStorage: ArticleDraftScope?
  public var title: String
  public var date: Date
  public var slug: String
  public var tags: [String]
  public var categories: [String]
  public var authors: [String]
  public var draft: Bool
  public var visibility: ArticleVisibility
  public var summary: String
  public var coverAttachmentID: UUID?
  public var bodyMarkdown: String
  public var attachments: [DraftAttachment]
  public var status: DraftStatus
  public var createdAt: Date
  public var updatedAt: Date
  public var repositoryPath: String?
  public var repositorySHA: String?
  /// Fingerprint of the repository content at the last successful import or
  /// direct publish. It intentionally stays unchanged while the user edits so
  /// background sync can prove that an existing draft is safe to replace.
  public var repositoryImportFingerprint: String?
  public var reusedFromSourceSnapshot: GeneralDraftReuseSourceSnapshot?
  /// Stable identity for built-in software guides. This is intentionally
  /// independent from the editable title and slug so user content with the
  /// same slug is never mistaken for an installed guide.
  public var softwareGuideID: String?
  /// Positive values identify an unmodified built-in guide template. A value
  /// of zero means the user customized the guide, while nil represents a guide
  /// saved before template-version tracking was introduced.
  public var softwareGuideTemplateVersion: Int?

  public init(
    id: UUID = UUID(),
    siteProfileID: UUID,
    scope: ArticleDraftScope? = nil,
    title: String,
    date: Date = Date(),
    slug: String = "",
    tags: [String] = [],
    categories: [String] = [],
    authors: [String] = [],
    draft: Bool = true,
    visibility: ArticleVisibility = .public,
    summary: String = "",
    coverAttachmentID: UUID? = nil,
    bodyMarkdown: String = "",
    attachments: [DraftAttachment] = [],
    status: DraftStatus = .draft,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    repositoryPath: String? = nil,
    repositorySHA: String? = nil,
    repositoryImportFingerprint: String? = nil,
    reusedFromSourceSnapshot: GeneralDraftReuseSourceSnapshot? = nil,
    softwareGuideID: String? = nil,
    softwareGuideTemplateVersion: Int? = nil
  ) {
    self.id = id
    let resolvedScope = scope ?? .site(siteProfileID)
    self.siteProfileID = resolvedScope.siteProfileID ?? siteProfileID
    self.scopeStorage = resolvedScope
    self.title = title
    self.date = date
    self.slug = slug
    self.tags = tags
    self.categories = categories
    self.authors = authors
    self.draft = draft
    self.visibility = visibility
    self.summary = summary
    self.coverAttachmentID = coverAttachmentID
    self.bodyMarkdown = bodyMarkdown
    self.attachments = attachments
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.repositoryPath = repositoryPath
    self.repositorySHA = repositorySHA
    self.repositoryImportFingerprint = repositoryImportFingerprint
    self.reusedFromSourceSnapshot = reusedFromSourceSnapshot
    self.softwareGuideID = softwareGuideID
    self.softwareGuideTemplateVersion = softwareGuideTemplateVersion
  }

  public var isPrivate: Bool {
    visibility == .private
  }

  public var scope: ArticleDraftScope {
    scopeStorage ?? .site(siteProfileID)
  }

  public var isGeneralDraft: Bool {
    scope.isGeneral
  }

  public func belongs(toSiteProfileID profileID: UUID) -> Bool {
    scope == .site(profileID)
  }

  public mutating func assignToSite(_ profileID: UUID) {
    siteProfileID = profileID
    scopeStorage = .site(profileID)
  }

  public mutating func assignToGeneralDraft(editingProfileID: UUID? = nil) {
    if let editingProfileID {
      siteProfileID = editingProfileID
    }
    scopeStorage = .general
    draft = true
    status = .draft
    repositoryPath = nil
    repositorySHA = nil
    repositoryImportFingerprint = nil
  }

  public mutating func normalizeLegacyScope() {
    if scopeStorage == nil {
      scopeStorage = .site(siteProfileID)
    }
  }

  /// Stable content identity for fields controlled by repository Markdown.
  /// Runtime identifiers, timestamps and remote SHAs are excluded so repeated
  /// imports of the same document remain a no-op.
  public var repositoryContentFingerprint: String {
    let coverRepositoryPath = coverAttachmentID.flatMap { coverID in
      attachments.first(where: { $0.id == coverID })?.repositoryPath.normalizedRelativePath()
    }
    let snapshot = RepositoryContentFingerprintSnapshot(
      title: title,
      date: date,
      slug: slug,
      tags: tags,
      categories: categories,
      authors: authors,
      draft: draft,
      visibility: visibility,
      summary: summary,
      coverRepositoryPath: coverRepositoryPath,
      bodyMarkdown: bodyMarkdown,
      attachments: attachments
        .map(RepositoryAttachmentFingerprintSnapshot.init)
        .sorted { lhs, rhs in
          if lhs.repositoryPath == rhs.repositoryPath {
            return lhs.relativePublishPath < rhs.relativePublishPath
          }
          return lhs.repositoryPath < rhs.repositoryPath
        },
      status: status
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let data = (try? encoder.encode(snapshot)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public mutating func touch() {
    updatedAt = Date()
  }

  public static func empty(profile: SiteProfile) -> ArticleDraft {
    let now = Date()
    return ArticleDraft(
      siteProfileID: profile.id,
      title: "未命名文章",
      date: now,
      slug: SlugService.fallbackSlug(date: now),
      tags: profile.defaultTags,
      categories: profile.defaultCategories,
      authors: profile.defaultAuthor.nilIfEmpty.map { [$0] } ?? [],
      bodyMarkdown: "# 未命名文章\n\n从这里开始写作。\n"
    )
  }

  public static func emptyGeneralDraft(editingProfile: SiteProfile) -> ArticleDraft {
    let now = Date()
    return ArticleDraft(
      siteProfileID: editingProfile.id,
      scope: .general,
      title: "未命名草稿",
      date: now,
      slug: SlugService.fallbackSlug(date: now),
      bodyMarkdown: "# 未命名草稿\n\n从这里开始写作。\n"
    )
  }

  /// Creates safe, editable guides for a brand-new workbench.
  ///
  /// Every guide remains a draft and has no repository path, so opening the
  /// application for the first time can never publish or overwrite a file.
  public static func samples(
    profile: SiteProfile,
    preferredLanguage: String? = Bundle.main.preferredLocalizations.first
      ?? Locale.preferredLanguages.first,
    now: Date = Date()
  ) -> [ArticleDraft] {
    let templates = sampleTemplates(preferredLanguage: preferredLanguage)
    let authors = profile.defaultAuthor.nilIfEmpty.map { [$0] } ?? []

    return templates.enumerated().map { index, template in
      let timestamp = now.addingTimeInterval(-TimeInterval(index * 60))
      return ArticleDraft(
        siteProfileID: profile.id,
        scope: .general,
        title: template.title,
        date: timestamp,
        slug: template.slug,
        tags: template.tags,
        categories: template.categories,
        authors: authors,
        draft: true,
        summary: template.summary,
        bodyMarkdown: template.bodyMarkdown,
        status: .draft,
        createdAt: timestamp,
        updatedAt: timestamp,
        softwareGuideID: template.id,
        softwareGuideTemplateVersion: currentSoftwareGuideSeedVersion
      )
    }
  }

  public static let currentSoftwareGuideSeedVersion = 4

  public struct SoftwareGuideSynchronizationResult: Sendable {
    public let drafts: [ArticleDraft]
    public let addedGuideCount: Int
    public let refreshedGuideCount: Int
  }

  /// Returns only the guides that are missing from the supplied drafts.
  ///
  /// Guide identity is independent from editable slugs. If a user-owned draft
  /// already occupies a guide slug, the new guide receives a numeric suffix
  /// instead of replacing or reclassifying the user's content.
  public static func missingSoftwareGuides(
    in existingDrafts: [ArticleDraft],
    profile: SiteProfile,
    preferredLanguage: String? = Bundle.main.preferredLocalizations.first
      ?? Locale.preferredLanguages.first,
    now: Date = Date()
  ) -> [ArticleDraft] {
    let guides = samples(
      profile: profile,
      preferredLanguage: preferredLanguage,
      now: now
    )
    let installedGuideIDs = Set(existingDrafts.compactMap(\.softwareGuideID))
    var occupiedSlugs = Set(
      existingDrafts.map { $0.slug.trimmedForPublishing.lowercased() }
    )

    return guides
      .filter { guide in
        guard let guideID = guide.softwareGuideID else { return false }
        return !installedGuideIDs.contains(guideID)
      }
      .map { guide in
        var resolvedGuide = guide
        let baseSlug = guide.slug
        var candidateSlug = baseSlug
        var suffix = 2
        while occupiedSlugs.contains(candidateSlug.trimmedForPublishing.lowercased()) {
          candidateSlug = "\(baseSlug)-\(suffix)"
          suffix += 1
        }
        resolvedGuide.slug = candidateSlug
        occupiedSlugs.insert(candidateSlug.trimmedForPublishing.lowercased())
        return resolvedGuide
      }
  }

  /// Installs newly introduced guides and refreshes unchanged built-in guides.
  ///
  /// Startup migrations do not restore guides that the user removed in an
  /// earlier version. An explicit Help-menu installation can opt into
  /// restoring every missing guide.
  public static func synchronizeSoftwareGuides(
    in existingDrafts: [ArticleDraft],
    profile: SiteProfile,
    previousSeedVersion: Int,
    restorePreviouslyRemovedGuides: Bool = false,
    preferredLanguage: String? = Bundle.main.preferredLocalizations.first
      ?? Locale.preferredLanguages.first,
    now: Date = Date()
  ) -> SoftwareGuideSynchronizationResult {
    let templates = samples(
      profile: profile,
      preferredLanguage: preferredLanguage,
      now: now
    )
    let templatesByID = Dictionary(
      uniqueKeysWithValues: templates.compactMap { guide in
        guide.softwareGuideID.map { ($0, guide) }
      }
    )
    let introducedVersionsByID = Dictionary(
      uniqueKeysWithValues: sampleTemplates(
        preferredLanguage: preferredLanguage
      ).map { ($0.id, $0.introducedInVersion) }
    )

    var refreshedGuideCount = 0
    var synchronizedDrafts = existingDrafts.map { draft in
      guard let guideID = draft.softwareGuideID,
            let template = templatesByID[guideID],
            shouldRefreshSoftwareGuide(draft)
      else {
        return draft
      }

      refreshedGuideCount += 1
      return refreshedSoftwareGuide(draft, from: template)
    }

    let installedGuideIDs = Set(synchronizedDrafts.compactMap(\.softwareGuideID))
    let eligibleMissingTemplates = templates.filter { guide in
      guard let guideID = guide.softwareGuideID,
            !installedGuideIDs.contains(guideID)
      else {
        return false
      }
      if restorePreviouslyRemovedGuides || previousSeedVersion == 0 {
        return true
      }
      return (introducedVersionsByID[guideID] ?? currentSoftwareGuideSeedVersion)
        > previousSeedVersion
    }
    let missingGuides = missingSoftwareGuides(
      in: synchronizedDrafts,
      profile: profile,
      preferredLanguage: preferredLanguage,
      now: now
    ).filter { missingGuide in
      eligibleMissingTemplates.contains {
        $0.softwareGuideID == missingGuide.softwareGuideID
      }
    }
    synchronizedDrafts.insert(contentsOf: missingGuides, at: 0)
    synchronizedDrafts = orderedSoftwareGuides(
      in: synchronizedDrafts,
      templates: templates
    )

    return SoftwareGuideSynchronizationResult(
      drafts: synchronizedDrafts,
      addedGuideCount: missingGuides.count,
      refreshedGuideCount: refreshedGuideCount
    )
  }

  private static func shouldRefreshSoftwareGuide(_ draft: ArticleDraft) -> Bool {
    guard draft.draft,
          draft.status == .draft,
          draft.repositoryPath == nil,
          draft.repositorySHA == nil
    else {
      return false
    }

    if let version = draft.softwareGuideTemplateVersion {
      return version > 0 && version < currentSoftwareGuideSeedVersion
    }
    return draft.updatedAt == draft.createdAt
  }

  private static func refreshedSoftwareGuide(
    _ existing: ArticleDraft,
    from template: ArticleDraft
  ) -> ArticleDraft {
    var refreshed = existing
    refreshed.title = template.title
    refreshed.tags = template.tags
    refreshed.categories = template.categories
    refreshed.authors = template.authors
    refreshed.summary = template.summary
    refreshed.bodyMarkdown = template.bodyMarkdown
    refreshed.assignToGeneralDraft(editingProfileID: template.siteProfileID)
    refreshed.softwareGuideTemplateVersion = currentSoftwareGuideSeedVersion
    return refreshed
  }

  private static func orderedSoftwareGuides(
    in drafts: [ArticleDraft],
    templates: [ArticleDraft]
  ) -> [ArticleDraft] {
    var orderedGuideDraftIDs: Set<UUID> = []
    let orderedGuides = templates.compactMap { template -> ArticleDraft? in
      guard let guideID = template.softwareGuideID,
            let guide = drafts.first(where: { $0.softwareGuideID == guideID })
      else {
        return nil
      }
      orderedGuideDraftIDs.insert(guide.id)
      return guide
    }
    return orderedGuides + drafts.filter {
      !orderedGuideDraftIDs.contains($0.id)
    }
  }

  private struct SampleTemplate {
    let id: String
    let introducedInVersion: Int
    let title: String
    let slug: String
    let tags: [String]
    let categories: [String]
    let summary: String
    let bodyMarkdown: String
  }

  private static func sampleTemplates(preferredLanguage: String?) -> [SampleTemplate] {
    let language = preferredLanguage?.lowercased() ?? "zh-hans"
    return language.hasPrefix("en") ? englishSampleTemplates : chineseSampleTemplates
  }

  private static let chineseSampleTemplates: [SampleTemplate] = [
    SampleTemplate(
      id: "getting-started",
      introducedInVersion: 1,
      title: "开始使用：认识发布工作台",
      slug: "personal-site-publisher-getting-started",
      tags: ["使用指南", "入门"],
      categories: ["指南"],
      summary: "认识顶部状态区、工作区导航、文章范围和检查器，并按推荐顺序完成第一次安全发布。",
      bodyMarkdown: """
      # 开始使用：认识发布工作台

      欢迎使用 RepoPress Studio。你正在阅读的“使用指南”默认位于通用草稿（Drafts），不会自动发布，也没有仓库写入路径。可以直接阅读、复制，或移到回收站；如果准备改写成自己的操作手册，建议先复制一份。

      ## 顶部：先看站点、状态和入口

      - **站点切换与本地预览**：确认正在编辑哪个网站，并打开本地预览。
      - **发布状态**：汇总仓库、当前文章和部署状态；点击后可进入对应页面或打开发布流程。
      - **全局搜索（⌘P）**：搜索草稿、标签和应用指令。
      - **直接操作按钮**：常用功能直接显示；在“写作”中可打开 AI 助手或右侧检查器。

      ## 左侧：按任务切换工作区

      工作区包含“写作、资料库、建站、仓库与发布、图片、内容健康、维护、发布记录”。中央区域随工作区显示编辑器、资料阅读、仓库差异或检查结果；右侧检查器显示当前任务的元数据与操作。窗口较窄或进入专注模式时，侧栏和检查器可能自动收起。

      写作列表上方有两个范围：

      - **当前站点（Current Site）**：属于当前网站，可进入检查和发布。
      - **草稿（Drafts）**：跨站点复用的通用草稿，不直接绑定仓库；需要时再转到某个站点。

      ## 推荐的第一次使用顺序

      1. 已有网站时，在“仓库与发布”选择本地仓库，并确认站点类型、分支、文章目录和图片目录。
      2. 还没有网站时，从“建站”选择模板，先审阅文件预览，再创建站点。
      3. 回到“写作”，新建或导入文章，补全标题、摘要、slug、标签和分类。
      4. 在“内容健康”修复阻断问题，然后打开顶部“发布状态”。
      5. 在发布抽屉审阅检查与差异，选择“保存到本地”或“发布所有变更”。
      6. 发布后到“发布记录”核对提交、PR/MR、自动化任务和部署结果。

      > 安全练习：修改本段文字，切换“编辑 / 预览 / 分屏”，再打开检查器。只要不执行保存或发布动作，仓库不会发生变化。
      """
    ),
    SampleTemplate(
      id: "writing-preview",
      introducedInVersion: 1,
      title: "写作与预览：完成第一篇文章",
      slug: "personal-site-publisher-writing-preview",
      tags: ["使用指南", "Markdown", "写作"],
      categories: ["指南"],
      summary: "选择文章范围，新建 Markdown 草稿，补全元数据，并通过预览、检查与版本记录完成一篇文章。",
      bodyMarkdown: """
      # 写作与预览：完成第一篇文章

      ## 1. 先选文章范围

      在“当前站点”中新建的文章属于当前网站，可以进入发布流程；在“草稿”中新建的是通用草稿，适合跨网站积累提纲和素材。确认范围后，点击文章列表上方的 **＋**。

      先填写清晰标题，再检查自动生成的 slug。slug 会成为文章路径的一部分，发布后尽量不要频繁修改。

      ## 2. 编辑、预览与分屏

      中央编辑器支持 Markdown、查找替换、常用格式、表格、链接和图片。显示模式包括：

      - **编辑**：集中输入，并使用单行快捷操作和格式化工具。
      - **预览**：检查标题层级、链接、代码块、表格和图片的最终效果。
      - **分屏**：一边修改，一边核对渲染结果；长文会尽量保持同步滚动。

      ## 3. 补全发布信息

      在右侧检查器完成摘要、日期、作者、标签、分类、公开范围和封面。摘要应能独立说明文章价值，标签和分类应少而稳定；图片需要可理解的 alt 文本。

      ## 4. 处理提示再发布

      编辑过程中可查看行内诊断、文章大纲和写作统计。完成后打开“内容健康”，先修复阻断问题，再决定保留草稿或标记为“待发布”。

      RepoPress Studio 会自动保存工作台。重要改动可在版本历史中比较和恢复；误删文章先到回收站查找。

      > 小练习：复制这一段，插入一个二级标题、一条链接和一个代码块，然后在分屏模式确认预览结果。
      """
    ),
    SampleTemplate(
      id: "ai-assistant",
      introducedInVersion: 2,
      title: "AI 助手：配置模型与管理多个对话",
      slug: "personal-site-publisher-ai-assistant",
      tags: ["使用指南", "AI", "写作"],
      categories: ["指南"],
      summary: "配置自己的 API 与模型，在当前文章或通用上下文中使用 AI，并管理多个可分支、可归档的对话。",
      bodyMarkdown: """
      # AI 助手：配置模型与管理多个对话

      AI 写作辅助和自定义 API 在独立免费版中直接开放。RepoPress Studio 不提供共享测试密钥，也不按请求次数收费；API 用量和费用由你选择的服务商决定。

      ## 1. 配置服务商

      打开“设置 → AI”，在“连接”中选择自定义 API 或本地服务，填写 Base URL 和模型名称。API Key 保存到系统钥匙串，不会写入文章或仓库。

      保存后先执行“测试连接”。只有理解将发送的文章上下文后，再确认 AI 数据共享授权。不要把密码、私钥、未公开客户资料或完整敏感文档发送给第三方模型。

      ## 2. 在写作页选择上下文和模型

      点击顶部 AI 助手按钮打开右侧面板：

      - 第一行显示当前对话；点击标题可切换历史，右侧按钮可新建对话。
      - 第二行选择“当前文章”或“通用聊天”，并直接选择模型档位与助手选项。
      - “快速、标准、高质量”会映射到当前服务商的模型；选择“自定义”后可输入具体模型名。

      “当前文章”会结合所选文章回答；“通用聊天”适合不依赖正文的问题。发送前仍应确认上下文范围。

      ## 3. 管理多个对话

      每篇文章可保留多个独立对话。点击对话标题后可以切换、重命名、归档、恢复或删除；在任意消息的菜单中选择“从这条消息处分支对话”，可以保留原讨论并探索另一种写法。

      ## 4. 安全应用结果

      快捷操作保持在一行，可用于润色、摘要、标题、标签、SEO 和检查。AI 返回内容后，优先使用“预览并追加”或 Diff 预览，确认变化后再写入正文；资料库引用应打开原文核对。自动化计划需要逐步确认，并在执行前查看可回滚范围。

      > AI 输出可能不准确。事实、日期、引用、链接和发布风险仍由你最终核对。
      """
    ),
    SampleTemplate(
      id: "knowledge-library",
      introducedInVersion: 1,
      title: "资料库：整理并引用长期资料",
      slug: "personal-site-publisher-knowledge-library",
      tags: ["使用指南", "资料库", "研究"],
      categories: ["指南"],
      summary: "导入本地文档或通过 Safari、Chrome、Firefox 保存网页，建立可搜索、可引用且保留来源的长期资料库。",
      bodyMarkdown: """
      # 资料库：整理并引用长期资料

      资料库适合保存研究材料、参考文档和长期笔记。它与文章草稿分开管理，因此你可以先整理来源，再决定哪些内容值得写进文章。

      ## 导入本地资料

      1. 在“资料库”选择导入入口，添加受支持的本地文档。
      2. 导入前核对标题和来源；网页和出版物应确认版权与引用范围。
      3. 导入后检查章节划分、正文识别和元数据，扫描型 PDF 可按需要使用 OCR。
      4. 使用标签、注释和收藏把资料整理为以后仍能理解的结构。

      ## 从浏览器保存网页

      打开“浏览器资料采集”查看本机连接和令牌。当前版本支持 Safari、Chrome 与 Firefox：

      - **Safari 扩展**已内嵌在 RepoPress Studio App 包内，只需到 Safari 设置中启用。
      - **Chrome 扩展**不包含在 App 包内，需要从 Chrome 网上应用店单独安装和更新。
      - **Firefox 扩展**不包含在 App 包内，从 `about:debugging` 临时加载 `BrowserExtension/Firefox/manifest.json`。

      扩展只连接 `127.0.0.1` 本机地址，并使用随机令牌验证。令牌只粘贴到你安装的扩展中，不要放到网页、文章或截图。Chrome 优先保存自包含 MHTML；Safari 和 Firefox 在大小上限内保存离线 HTML。应用暂时关闭时，扩展会在浏览器本地排队并稍后重试。

      ## 搜索与引用

      先用全文搜索定位原文，再查看关联章节或本地语义结果。把内容带入文章时，优先插入短引用、来源名称和链接，不要复制整篇原文。

      AI 助手可以基于选中资料总结或拟定提纲，并显示资料库引用；仍应打开原文核对事实、日期和上下文。

      ## 保持资料库可靠

      - 为重要资料保留明确来源。
      - 定期处理重复、失效或解析不完整的条目。
      - 批量整理或恢复之前先创建资料库备份。
      - 不要把账号令牌、私人密钥或敏感客户资料导入普通资料库。
      """
    ),
    SampleTemplate(
      id: "safe-publishing",
      introducedInVersion: 1,
      title: "安全发布：连接仓库、检查并提交",
      slug: "personal-site-publisher-safe-publishing",
      tags: ["使用指南", "Git", "发布"],
      categories: ["指南"],
      summary: "配置仓库后按“检查 → 保存到本地 / 发布上线”完成发布，并在最终确认前审阅完整差异。",
      bodyMarkdown: """
      # 安全发布：连接仓库、检查并提交

      最新发布流程集中回答两个问题：文件是否安全，以及这次只保存到本地还是发布上线。分支、远端、同步、历史和部署管理统一放在“仓库与发布”页面。

      ## 1. 配置站点

      在“仓库与发布”或设置中确认站点类型、本地仓库、远端提供商、仓库名称、目标分支、文章目录和图片目录。访问令牌应保存到系统钥匙串，不要写进文章、仓库或截图。

      获取远端变化后，先阅读仓库状态和 Diff。若同一篇文章已经在远端更新，应先导入、合并或重新确认内容，不要直接覆盖。

      ## 2. 打开统一发布流程

      点击顶部“发布状态”并进入发布。抽屉会自动执行文章检查和文件预览：

      1. 先看“发布准备”中的文件变化、阻断问题和提醒。
      2. 有问题时先修复；不要通过最终确认绕过阻断项。
      3. 展开“检查文件变化”，审阅全部检查结果和逐文件 Diff。
      4. 最后再选择具体操作。

      - 没有本机绝对路径、令牌、邮箱或其他敏感信息。
      - 标题、slug、摘要、封面和内部链接符合站点规则。
      - 图片源文件存在，并且 alt 文本能说明图片内容。
      - 本次 Diff 只包含你准备处理的文件。

      ## 3. 区分两个主要操作

      - **保存到本地**：只更新本地站点文件，不执行 Git 提交，也不会上传网站。
      - **发布所有变更**：汇总当前站点中所有通过检查且有变化的文章，进入最终确认后提交并推送。需要缩小范围时可选择“仅发布当前文章”。

      最终确认页会再次显示远端、分支、发布方式和完整文件清单。日常发布优先使用 PR/MR；完成后到“发布记录”核对提交、自动化任务、部署状态和最终页面。
      """
    ),
    SampleTemplate(
      id: "maintenance-recovery",
      introducedInVersion: 1,
      title: "发布之后：图片、维护与版本恢复",
      slug: "personal-site-publisher-maintenance",
      tags: ["使用指南", "图片", "维护"],
      categories: ["指南"],
      summary: "用图片工作台、内容健康、维护报告和版本历史保持网站长期清晰、稳定、可恢复。",
      bodyMarkdown: """
      # 发布之后：图片、维护与版本恢复

      一个可靠的网站需要持续维护，而不只是完成一次发布。

      ## 图片

      在“图片”工作区统一检查附件、封面、尺寸、格式、alt 文本和说明。优化或转换图片前先查看影响范围；不要用压缩后的临时文件覆盖唯一原图。

      ## 内容健康

      发布前后都可以运行内容健康检查，重点关注空标题、重复 slug、无效链接、缺失图片、公开风险和不完整元数据。先解决错误，再评估警告是否适用于当前文章。

      ## 日常维护

      维护报告可帮助整理旧文章、标签、发布时间和站内链接。每次只处理一个边界清楚的小批次，并在执行写入前阅读预览。

      ## 恢复与追踪

      - 使用文章版本历史比较改动，必要时恢复正文。
      - 误删文章先到回收站恢复，不要立即手动删除仓库文件。
      - 在“仓库与发布”处理分支、远端和同步，在“发布记录”查看提交、PR/MR 和部署结果。
      - 定期备份工作台和资料库；备份验证通过后再清理旧副本。

      当你已经熟悉这些流程，可以删除这组示例文章，或把它们改成自己的发布操作手册。
      """
    ),
  ]

  private static let englishSampleTemplates: [SampleTemplate] = [
    SampleTemplate(
      id: "getting-started",
      introducedInVersion: 1,
      title: "Getting Started: Meet Your Publishing Workbench",
      slug: "personal-site-publisher-getting-started",
      tags: ["Guide", "Getting Started"],
      categories: ["Guides"],
      summary: "Learn the top status area, workspace navigation, draft scopes, and the recommended path to a safe first release.",
      bodyMarkdown: """
      # Getting Started: Meet Your Publishing Workbench

      Welcome to RepoPress Studio. These Guide articles live in general Drafts by default. They are never published automatically and have no repository write path. Read, duplicate, or move them to the recycle bin. If you want to turn one into your own runbook, duplicate it first.

      ## Top bar: site, status, and entry points

      - **Site switcher and local preview** confirm which site you are editing and open its local preview.
      - **Publishing status** summarizes the repository, current article, and deployment. Click it to open the relevant area or publishing flow.
      - **Global search (⌘P)** finds drafts, tags, and app commands.
      - **Direct action buttons** expose frequent tools. In Writing, open the AI Assistant or the inspector from the top bar.

      ## Left side: switch by task

      The workspaces are Writing, Library, Site Starter, Repository & Publish, Images, Content Health, Maintenance, and Release History. The center shows the editor, source reader, repository differences, or checks; the right inspector follows the current task. Sidebars may collapse in a narrow window or Focus Mode.

      Writing has two content scopes:

      - **Current Site** contains site-owned articles that can enter the publishing flow.
      - **Drafts** contains reusable general drafts that are not directly bound to a repository.

      ## A good first-use sequence

      1. For an existing site, choose its local repository in Repository & Publish, then confirm the site type, branch, content path, and image path.
      2. For a new site, choose a template in Site Starter and review the file preview before creation.
      3. Return to Writing, create or import an article, and complete its title, summary, slug, tags, and category.
      4. Resolve blocking issues in Content Health, then open Publishing Status.
      5. Review checks and file differences, then choose Save Locally or Publish All Changes.
      6. Verify commits, pull or merge requests, automation, and deployment in Release History.

      > Safe exercise: edit this paragraph, switch among Edit, Preview, and Split, then open the inspector. The repository stays unchanged until you explicitly save or publish.
      """
    ),
    SampleTemplate(
      id: "writing-preview",
      introducedInVersion: 1,
      title: "Writing and Preview: Finish Your First Article",
      slug: "personal-site-publisher-writing-preview",
      tags: ["Guide", "Markdown", "Writing"],
      categories: ["Guides"],
      summary: "Choose a draft scope, write in Markdown, complete metadata, and use previews, checks, and versions to finish an article.",
      bodyMarkdown: """
      # Writing and Preview: Finish Your First Article

      ## 1. Choose the draft scope

      Articles created under Current Site belong to the active site and can enter publishing. Drafts are reusable general drafts for outlines and material shared across sites. Choose the scope, then click **＋** above the article list.

      Start with a clear title, then review the generated slug. The slug becomes part of the article path, so avoid changing it frequently after publication.

      ## 2. Edit, preview, and split

      The editor supports Markdown, find and replace, common formatting, tables, links, and images. Display modes include:

      - **Edit** for focused typing with one-row quick and formatting actions.
      - **Preview** to check headings, links, code blocks, tables, and images.
      - **Split** to edit beside the rendered result; long documents keep the two panes synchronized where possible.

      ## 3. Complete publishing metadata

      Use the inspector to fill in the summary, date, author, tags, category, visibility, and cover. A summary should explain the article on its own, labels should remain consistent, and images need meaningful alt text.

      ## 4. Resolve feedback before release

      Use inline diagnostics, the outline, and writing statistics. When ready, open Content Health, fix blocking issues, and then keep the article as a draft or mark it Ready.

      RepoPress Studio autosaves the workbench. Compare and restore important revisions in version history, and check the recycle bin before treating an accidental deletion as permanent.

      > Exercise: duplicate this paragraph, add a level-two heading, a link, and a code block, then confirm the result in Split mode.
      """
    ),
    SampleTemplate(
      id: "ai-assistant",
      introducedInVersion: 2,
      title: "AI Assistant: Choose Models and Manage Conversations",
      slug: "personal-site-publisher-ai-assistant",
      tags: ["Guide", "AI", "Writing"],
      categories: ["Guides"],
      summary: "Configure your own API and model, use article or general context, and manage multiple conversations with branches and archives.",
      bodyMarkdown: """
      # AI Assistant: Choose Models and Manage Conversations

      AI writing tools and custom APIs are available directly in the free standalone edition. RepoPress Studio does not provide a shared test key or charge per request; usage and billing come from the provider you configure.

      ## 1. Configure a provider

      Open Settings → AI → Connection. Choose Custom API or a local service, then enter the Base URL and model. API keys are stored in the system Keychain and are never written into an article or repository.

      Save the key and run Test Connection. Grant AI data-sharing consent only after you understand which article context will be sent. Never send passwords, private keys, unreleased client material, or complete sensitive documents to a third-party model.

      ## 2. Choose context and model while writing

      Open the AI Assistant from the top bar:

      - The first row shows the current conversation. Click its title to switch history; use the button on the right to start a new conversation.
      - The second row selects Current Article or General Chat, the model tier, and assistant options.
      - Fast, Standard, and High Quality map to provider-specific models. Choose Custom to enter an exact model name.

      Current Article uses the selected article as context. General Chat is for questions that do not depend on its body. Always confirm the context before sending.

      ## 3. Manage multiple conversations

      Each article can keep several independent conversations. Open the conversation title to switch, rename, archive, restore, or delete. Use “Branch Conversation from This Message” in a message menu to preserve the original discussion while exploring another direction.

      ## 4. Apply results safely

      One-row quick actions cover rewriting, summaries, titles, tags, SEO, and checks. Prefer Preview and Append or a Diff preview before changing the article. Open Library citations and verify the source. Review every automation step and its rollback scope before execution.

      > AI output can be wrong. You remain responsible for facts, dates, citations, links, and publishing risks.
      """
    ),
    SampleTemplate(
      id: "knowledge-library",
      introducedInVersion: 1,
      title: "Library: Organize and Cite Long-Term Sources",
      slug: "personal-site-publisher-knowledge-library",
      tags: ["Guide", "Library", "Research"],
      categories: ["Guides"],
      summary: "Import local documents or save pages from Safari, Chrome, and Firefox to build a searchable, citable library with clear provenance.",
      bodyMarkdown: """
      # Library: Organize and Cite Long-Term Sources

      The Library is for research material, reference documents, and long-lived notes. It is separate from article drafts, so you can organize evidence before deciding what belongs in a post.

      ## Import local material

      1. In Library, use the import entry point to add a supported local document.
      2. Review its title and source before import, and respect copyright and quotation limits.
      3. After import, inspect chapter boundaries, extracted text, and metadata. Use OCR only when a scanned PDF needs it.
      4. Add tags, annotations, and favorites that will still make sense months later.

      ## Save pages from a browser

      Open Browser Capture to see the local connection and token. This release supports Safari, Chrome, and Firefox:

      - The **Safari extension** is embedded in the RepoPress Studio app bundle; enable it in Safari Settings.
      - The **Chrome extension is not included in the app bundle**. Install and update it separately through the Chrome Web Store.
      - The **Firefox extension is not included in the app bundle**. Load `BrowserExtension/Firefox/manifest.json` temporarily from `about:debugging`.

      Extensions connect only to `127.0.0.1` and authenticate with a random token. Paste that token only into your installed extension—never into a webpage, article, or screenshot. Chrome prefers self-contained MHTML; Safari and Firefox save offline HTML within their size limit. If RepoPress Studio is closed, the extension queues the item locally and retries later.

      ## Search and cite

      Begin with full-text search, then inspect related chapters or local semantic results. Prefer a short quotation, source name, and link instead of copying an entire document.

      The AI Assistant can summarize selected material or draft an outline with Library citations. Open the source and verify facts, dates, and context.

      ## Keep the library reliable

      - Preserve a clear source for important material.
      - Review duplicates, broken sources, and incomplete extraction regularly.
      - Create a library backup before large cleanup or restore operations.
      - Never import account tokens, private keys, or sensitive client material into a normal library.
      """
    ),
    SampleTemplate(
      id: "safe-publishing",
      introducedInVersion: 1,
      title: "Safe Publishing: Connect, Review, and Commit",
      slug: "personal-site-publisher-safe-publishing",
      tags: ["Guide", "Git", "Publishing"],
      categories: ["Guides"],
      summary: "Configure a repository, follow Check → Save Locally or Publish Online, and review the complete diff before final confirmation.",
      bodyMarkdown: """
      # Safe Publishing: Connect, Review, and Commit

      The current publishing flow answers two questions: are the files safe, and should this operation only save locally or go online? Branch, remote, synchronization, history, and deployment management live in Repository & Publish.

      ## 1. Configure the site

      In Repository & Publish or Settings, confirm the site type, local repository, remote provider, repository name, target branch, content path, and image path. Store access tokens in the system Keychain—never in an article, repository, or screenshot.

      Fetch remote changes and read the repository status and Diff. If the same article changed upstream, import, merge, or review it again instead of overwriting it.

      ## 2. Open the unified publishing flow

      Click Publishing Status in the top bar and open Publish. The drawer prepares article checks and a file preview:

      1. Read file changes, blocking issues, and warnings in Publishing Preparation.
      2. Fix blockers instead of trying to bypass them in final confirmation.
      3. Expand Review File Changes to inspect every check and per-file Diff.
      4. Choose the operation only after the review.

      - No local absolute path, token, email address, or sensitive value is exposed.
      - The title, slug, summary, cover, and internal links follow site rules.
      - Image source files exist and alt text describes their content.
      - The Diff contains only the files you intend to process.

      ## 3. Distinguish the primary actions

      - **Save Locally** updates site files only. It does not create a Git commit or upload the website.
      - **Publish All Changes** collects every changed article in the current site that passed checks, then commits and pushes after final confirmation. Choose Publish Current Article when you need a narrower scope.

      Final confirmation repeats the remote, branch, publish method, and complete file list. Prefer a pull or merge request for routine work, then verify the commit, automation, deployment, and final page in Release History.
      """
    ),
    SampleTemplate(
      id: "maintenance-recovery",
      introducedInVersion: 1,
      title: "After Publishing: Images, Maintenance, and Recovery",
      slug: "personal-site-publisher-maintenance",
      tags: ["Guide", "Images", "Maintenance"],
      categories: ["Guides"],
      summary: "Use image tools, content checks, maintenance reports, and version history to keep the site clear and recoverable.",
      bodyMarkdown: """
      # After Publishing: Images, Maintenance, and Recovery

      A dependable site needs ongoing care, not just a successful first release.

      ## Images

      Use Images to review attachments, covers, dimensions, formats, alt text, and captions. Check the affected files before optimization or conversion, and never replace your only original with a temporary compressed copy.

      ## Content Health

      Run Content Health before and after release. Pay particular attention to empty titles, duplicate slugs, broken links, missing images, public-exposure risks, and incomplete metadata. Fix errors first, then decide whether each warning applies.

      ## Routine maintenance

      Maintenance reports help review older posts, tags, publishing dates, and internal links. Work in small, clearly scoped batches and read every preview before a write operation.

      ## Recovery and traceability

      - Compare article versions and restore content when necessary.
      - Recover accidental deletions from the recycle bin before touching repository files manually.
      - Manage branches, remotes, and synchronization in Repository & Publish; inspect commits, pull/merge requests, and deployments in Release History.
      - Back up the workbench and Library regularly, and verify a backup before deleting older copies.

      Once these workflows feel familiar, delete the sample articles or adapt them into your own publishing runbook.
      """
    ),
  ]
}

private struct RepositoryContentFingerprintSnapshot: Encodable {
  var title: String
  var date: Date
  var slug: String
  var tags: [String]
  var categories: [String]
  var authors: [String]
  var draft: Bool
  var visibility: ArticleVisibility
  var summary: String
  var coverRepositoryPath: String?
  var bodyMarkdown: String
  var attachments: [RepositoryAttachmentFingerprintSnapshot]
  var status: DraftStatus
}

private struct RepositoryAttachmentFingerprintSnapshot: Encodable {
  var originalFilename: String
  var relativePublishPath: String
  var repositoryPath: String
  var altText: String
  var caption: String

  init(_ attachment: DraftAttachment) {
    originalFilename = attachment.originalFilename
    relativePublishPath = attachment.relativePublishPath.normalizedRelativePath()
    repositoryPath = attachment.repositoryPath.normalizedRelativePath()
    altText = attachment.altText
    caption = attachment.caption
  }
}
