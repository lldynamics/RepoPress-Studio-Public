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

  public init(
    id: UUID = UUID(),
    originalFilename: String,
    relativePublishPath: String,
    repositoryPath: String,
    altText: String = "",
    caption: String = "",
    byteSize: Int64 = 0,
    sourceFilePath: String? = nil,
    repositorySHA: String? = nil
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
  public var siteProfileID: UUID
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
  public var reusedFromSourceSnapshot: GeneralDraftReuseSourceSnapshot?

  public init(
    id: UUID = UUID(),
    siteProfileID: UUID,
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
    reusedFromSourceSnapshot: GeneralDraftReuseSourceSnapshot? = nil
  ) {
    self.id = id
    self.siteProfileID = siteProfileID
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
    self.reusedFromSourceSnapshot = reusedFromSourceSnapshot
  }

  public var isPrivate: Bool {
    visibility == .private
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

  public static func samples(profile: SiteProfile) -> [ArticleDraft] {
    [
      ArticleDraft(
        siteProfileID: profile.id,
        title: "Mac 发布控制台 MVP",
        slug: "mac-publishing-console-mvp",
        tags: ["Mac", "发布"],
        categories: ["Product"],
        draft: true,
        summary: "把个人网站写作、检查、本地仓库和发布说明收在一个桌面工作台。",
        bodyMarkdown: """
        # Mac 发布控制台 MVP

        这篇文章用于验证桌面版编辑器、Front Matter、预检和本地仓库检查链路。

        - 顶部切换写作、同步、内容健康、图片和发布记录
        - 左侧保持写作草稿列表
        - 中间只负责 Markdown 编辑
        - 右侧完成元数据、SEO、图片和发布检查
        """
      ),
      ArticleDraft(
        siteProfileID: profile.id,
        title: "本地仓库发布链路",
        slug: "local-repository-publish-flow",
        tags: ["Git", "Workflow"],
        categories: ["Engineering"],
        draft: false,
        summary: "只做文章发布需要的 Git：路径检查、diff 摘要、提交和 PR/MR。",
        bodyMarkdown: """
        # 本地仓库发布链路

        Mac 版应该把真实仓库作为一等入口，但不要扩成完整 Git 客户端。
        """
      ),
    ]
  }
}
