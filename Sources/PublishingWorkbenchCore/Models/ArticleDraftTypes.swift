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
    guard case .site(let profileID) = self else { return nil }
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

  public static func make(from draft: ArticleDraft, sourceProfileName: String)
    -> GeneralDraftReuseSourceSnapshot
  {
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

/// The draft fields used by editor metadata projections.  Deliberately
/// excludes the body, derived word count and the content-write timestamp so an
/// autosave cannot invalidate those projections.
public struct ArticleDraftMetadataProjection: Equatable, Hashable, Sendable {
  public let id: UUID
  public let siteProfileID: UUID
  public let scope: ArticleDraftScope
  public let title: String
  public let date: Date
  public let slug: String
  public let tags: [String]
  public let categories: [String]
  public let authors: [String]
  public let aliases: [String]
  public let pendingSlugRedirectPaths: [String]
  public let permalink: String?
  public let draft: Bool
  public let visibility: ArticleVisibility
  public let summary: String
  public let coverAttachmentID: UUID?
  public let attachments: [DraftAttachment]
  public let status: DraftStatus
  public let createdAt: Date
  public let repositoryPath: String?
  public let softwareGuideID: String?
  public let softwareGuideTemplateVersion: Int?

  init(draft: ArticleDraft) {
    id = draft.id
    siteProfileID = draft.siteProfileID
    scope = draft.scope
    title = draft.title
    date = draft.date
    slug = draft.slug
    tags = draft.tags
    categories = draft.categories
    authors = draft.authors
    aliases = draft.aliases
    pendingSlugRedirectPaths = draft.pendingSlugRedirectPaths
    permalink = draft.permalink
    self.draft = draft.draft
    visibility = draft.visibility
    summary = draft.summary
    coverAttachmentID = draft.coverAttachmentID
    attachments = draft.attachments
    status = draft.status
    createdAt = draft.createdAt
    repositoryPath = draft.repositoryPath
    softwareGuideID = draft.softwareGuideID
    softwareGuideTemplateVersion = draft.softwareGuideTemplateVersion
  }
}

/// The editor's observable metadata plus its optimistic-lock token. Keeping
/// the token in this projection makes a repository/import replacement visible
/// to an open editor even when the resulting front matter is textually equal.
public struct ArticleDraftEditorObservationProjection: Equatable, Hashable, Sendable {
  public let metadata: ArticleDraftMetadataProjection
  public let revision: UInt64

  init(draft: ArticleDraft) {
    metadata = draft.metadataProjection
    revision = draft.editorMetadataRevision
  }
}

/// The narrow draft projection consumed by the Writing list.
///
/// This is intentionally stricter than `ArticleDraftMetadataProjection`:
/// repository CAS state, attachments, software-guide bookkeeping and other
/// editor/persistence details must not rebuild folder/search topology.  The
/// metadata timestamp is list-visible because it is the stable tie-breaker for
/// the "updated" ordering; body writes preserve it.
public struct ArticleDraftListMetadataProjection: Equatable, Hashable, Sendable {
  public let id: UUID
  public let siteProfileID: UUID
  public let scope: ArticleDraftScope
  public let title: String
  public let date: Date
  public let slug: String
  public let tags: [String]
  public let categories: [String]
  public let summary: String
  public let visibility: ArticleVisibility
  public let status: DraftStatus
  public let metadataUpdatedAt: Date

  init(draft: ArticleDraft) {
    id = draft.id
    siteProfileID = draft.siteProfileID
    scope = draft.scope
    title = draft.title
    date = draft.date
    slug = draft.slug
    tags = draft.tags
    categories = draft.categories
    summary = draft.summary
    visibility = draft.visibility
    status = draft.status
    metadataUpdatedAt = draft.metadataUpdatedAt
  }
}
