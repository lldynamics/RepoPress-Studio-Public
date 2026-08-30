import CryptoKit
import Foundation

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
  /// Optional storage keeps workbench snapshots written before digital-garden
  /// aliases backward compatible.
  private var aliasesStorage: [String]?
  /// Routes replaced by an editor-committed Slug change. They stay separate
  /// from `aliases` until the user chooses whether to rewrite references or
  /// keep the old route as a redirect. Optional storage keeps older snapshots
  /// backward compatible.
  private var pendingSlugRedirectPathsStorage: [String]?
  /// A framework-provided route override such as Quartz `permalink`.
  public var permalink: String?
  public var draft: Bool
  public var visibility: ArticleVisibility
  public var summary: String
  public var coverAttachmentID: UUID?
  public var bodyMarkdown: String {
    didSet {
      if bodyMarkdown != oldValue {
        wordCountNeedsRefreshStorage = true
      }
    }
  }
  /// Persisted writing-unit count used by list rows and other lightweight projections.
  /// Optional backing storage keeps snapshots created before this field backward compatible.
  private var wordCountStorage: Int?
  /// Missing legacy values are dirty so the next body commit refreshes the count.
  private var wordCountNeedsRefreshStorage: Bool?
  public var attachments: [DraftAttachment]
  public var status: DraftStatus
  public var createdAt: Date
  public var updatedAt: Date
  /// Metadata-only timestamp used by list ordering and row presentation. The
  /// optional backing storage keeps old snapshots compatible and falls back
  /// to the historical `updatedAt` value until the first edit.
  private var metadataUpdatedAtStorage: Date?
  /// Monotonic optimistic-lock token for editor metadata. The optional
  /// backing storage keeps older snapshots compatible; legacy drafts resolve
  /// to revision zero until their first metadata edit.
  private var editorMetadataRevisionStorage: UInt64?
  public var repositoryPath: String?
  public var repositorySHA: String?
  /// Fingerprint of the repository content at the last successful import or
  /// direct publish. It intentionally stays unchanged while the user edits so
  /// background sync can prove that an existing draft is safe to replace.
  public var repositoryImportFingerprint: String?
  /// Atomic repository ownership and sync state. The three legacy projections above remain
  /// encoded during migration, while repository-aware flows update this value as a unit.
  public private(set) var repositoryBinding: DraftRepositoryBinding?
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
    aliases: [String] = [],
    pendingSlugRedirectPaths: [String] = [],
    permalink: String? = nil,
    draft: Bool = true,
    visibility: ArticleVisibility = .public,
    summary: String = "",
    coverAttachmentID: UUID? = nil,
    bodyMarkdown: String = "",
    wordCount: Int? = nil,
    attachments: [DraftAttachment] = [],
    status: DraftStatus = .draft,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    metadataUpdatedAt: Date? = nil,
    editorMetadataRevision: UInt64? = nil,
    repositoryPath: String? = nil,
    repositorySHA: String? = nil,
    repositoryImportFingerprint: String? = nil,
    repositoryBinding: DraftRepositoryBinding? = nil,
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
    self.aliasesStorage = aliases.isEmpty ? nil : aliases
    self.pendingSlugRedirectPathsStorage =
      pendingSlugRedirectPaths.isEmpty
      ? nil
      : pendingSlugRedirectPaths
    self.permalink = permalink?.trimmedForPublishing.nilIfEmpty
    self.draft = draft
    self.visibility = visibility
    self.summary = summary
    self.coverAttachmentID = coverAttachmentID
    self.bodyMarkdown = bodyMarkdown
    self.wordCountStorage = wordCount.map { max(0, $0) }
    self.wordCountNeedsRefreshStorage = wordCount == nil
    self.attachments = attachments
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.metadataUpdatedAtStorage = metadataUpdatedAt
    self.editorMetadataRevisionStorage = editorMetadataRevision
    self.repositoryPath = repositoryPath
    self.repositorySHA = repositorySHA
    self.repositoryImportFingerprint = repositoryImportFingerprint
    self.repositoryBinding =
      repositoryBinding
      ?? Self.legacyRepositoryBinding(
        path: repositoryPath,
        remoteRevision: repositorySHA
      )
    self.reusedFromSourceSnapshot = reusedFromSourceSnapshot
    self.softwareGuideID = softwareGuideID
    self.softwareGuideTemplateVersion = softwareGuideTemplateVersion
  }

  public var wordCount: Int {
    wordCountStorage ?? 0
  }

  public var wordCountNeedsRefresh: Bool {
    wordCountNeedsRefreshStorage ?? true
  }

  /// Stable metadata timestamp for list ordering. Legacy drafts retain their
  /// old ordering until an edit explicitly creates the new storage value.
  public var metadataUpdatedAt: Date {
    metadataUpdatedAtStorage ?? updatedAt
  }

  public var editorMetadataRevision: UInt64 {
    editorMetadataRevisionStorage ?? 0
  }

  public var metadataProjection: ArticleDraftMetadataProjection {
    ArticleDraftMetadataProjection(draft: self)
  }

  public var editorObservationProjection: ArticleDraftEditorObservationProjection {
    ArticleDraftEditorObservationProjection(draft: self)
  }

  public var listMetadataProjection: ArticleDraftListMetadataProjection {
    ArticleDraftListMetadataProjection(draft: self)
  }

  public func hasSameListMetadata(as other: ArticleDraft) -> Bool {
    id == other.id
      && siteProfileID == other.siteProfileID
      && scope == other.scope
      && title == other.title
      && date == other.date
      && slug == other.slug
      && tags == other.tags
      && categories == other.categories
      && summary == other.summary
      && visibility == other.visibility
      && status == other.status
  }

  /// Whether editor-owned metadata (including attachments) is unchanged.
  /// Repository CAS state remains outside this projection and therefore does
  /// not invalidate an editor's optimistic metadata revision.
  public func hasSameEditorMetadata(as other: ArticleDraft) -> Bool {
    metadataProjection == other.metadataProjection
  }

  /// Whether two values differ only in body/derived-count/content timestamp.
  /// This is the change-kind discriminator used by the editor autosave path.
  public func hasSameMetadata(as other: ArticleDraft) -> Bool {
    metadataProjection == other.metadataProjection
      && repositorySHA == other.repositorySHA
      && repositoryImportFingerprint == other.repositoryImportFingerprint
      && repositoryBinding == other.repositoryBinding
      && reusedFromSourceSnapshot == other.reusedFromSourceSnapshot
  }

  /// Records a metadata mutation.  `updatedAt` remains the content-write
  /// timestamp while `metadataUpdatedAt` advances only for list-visible
  /// metadata changes.
  public mutating func markMetadataUpdated(
    at date: Date = Date(),
    replacing previous: ArticleDraft? = nil
  ) {
    updatedAt = date
    metadataUpdatedAtStorage = date
    if let previous {
      editorMetadataRevisionStorage = previous.editorMetadataRevision
    }
    bumpEditorMetadataRevision()
  }

  /// Records a non-list editor metadata mutation, such as an attachment
  /// change. It advances the editor optimistic-lock token without reshuffling
  /// the list's metadata ordering.
  public mutating func markEditorMetadataUpdated(at date: Date = Date()) {
    if metadataUpdatedAtStorage == nil {
      metadataUpdatedAtStorage = updatedAt
    }
    updatedAt = date
    bumpEditorMetadataRevision()
  }

  /// Records a body/derived-content mutation without moving the metadata
  /// ordering/optimistic-lock timestamp.
  public mutating func markBodyUpdated(
    at date: Date = Date(),
    preservingMetadataUpdatedAt metadataDate: Date? = nil
  ) {
    if let metadataDate {
      metadataUpdatedAtStorage = metadataDate
    } else if metadataUpdatedAtStorage == nil {
      metadataUpdatedAtStorage = updatedAt
    }
    updatedAt = date
  }

  /// Finalizes a replacement value against the live draft it supersedes.
  /// This keeps the list clock, editor lock and general content clock aligned
  /// even when the replacement was decoded/imported with an unrelated token.
  public mutating func markUpdated(
    at date: Date = Date(),
    replacing previous: ArticleDraft
  ) {
    if !previous.hasSameListMetadata(as: self) {
      markMetadataUpdated(at: date, replacing: previous)
    } else if !previous.hasSameEditorMetadata(as: self) {
      editorMetadataRevisionStorage = previous.editorMetadataRevision
      markEditorMetadataUpdated(at: date)
    } else {
      editorMetadataRevisionStorage = previous.editorMetadataRevision
      markBodyUpdated(
        at: date,
        preservingMetadataUpdatedAt: previous.metadataUpdatedAt
      )
    }
  }

  private mutating func bumpEditorMetadataRevision() {
    editorMetadataRevisionStorage = editorMetadataRevision &+ 1
  }

  /// Applies an asynchronously derived count only when it still describes the current body.
  @discardableResult
  public mutating func storeWordCount(_ count: Int, for bodyMarkdown: String) -> Bool {
    guard self.bodyMarkdown == bodyMarkdown else { return false }
    wordCountStorage = max(0, count)
    wordCountNeedsRefreshStorage = false
    return true
  }

  public var isPrivate: Bool {
    visibility == .private
  }

  public var aliases: [String] {
    get { aliasesStorage ?? [] }
    set { aliasesStorage = newValue.isEmpty ? nil : newValue }
  }

  public var pendingSlugRedirectPaths: [String] {
    get { pendingSlugRedirectPathsStorage ?? [] }
    set { pendingSlugRedirectPathsStorage = newValue.isEmpty ? nil : newValue }
  }

  public mutating func recordPendingSlugRedirectPath(_ path: String) {
    let normalized = Self.normalizedRedirectPath(path)
    guard normalized != "/", !pendingSlugRedirectPaths.contains(normalized) else { return }
    pendingSlugRedirectPaths.append(normalized)
  }

  public mutating func clearPendingSlugRedirectPaths() {
    pendingSlugRedirectPathsStorage = nil
  }

  private static func normalizedRedirectPath(_ value: String) -> String {
    var path = value.trimmedForPublishing
    path = String(path.split(separator: "#", maxSplits: 1).first ?? "")
    path = String(path.split(separator: "?", maxSplits: 1).first ?? "")
    guard !path.isEmpty,
      !path.contains("://"),
      !path.hasPrefix("//"),
      !path.contains("\\")
    else { return "/" }
    let components = path.split(separator: "/").map(String.init)
    guard !components.contains("..") else { return "/" }
    return "/" + components.joined(separator: "/") + "/"
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
    detachFromRepository()
  }

  public mutating func normalizeLegacyScope() {
    if scopeStorage == nil {
      scopeStorage = .site(siteProfileID)
    }
  }

  /// Migrates pre-binding snapshots and invalidates a revision that belongs to another
  /// repository or branch. Local project placement is retained, but remote CAS evidence is
  /// cleared until the new target is verified.
  public mutating func normalizeRepositoryBinding(for profile: SiteProfile) {
    guard let path = repositoryPath?.normalizedRelativePath().nilIfEmpty else {
      repositoryBinding = nil
      repositorySHA = nil
      repositoryImportFingerprint = nil
      return
    }

    let identity = DraftRepositoryIdentity(profile: profile)
    if var binding = repositoryBinding {
      if let boundIdentity = binding.identity, boundIdentity != identity {
        binding = DraftRepositoryBinding(
          identity: identity,
          repositoryPath: path,
          renderedContentDigest: nil,
          verification: .legacyUnverified,
          syncState: .projectSaved
        )
        repositorySHA = nil
        repositoryImportFingerprint = nil
      } else {
        binding.identity = identity
        binding.repositoryPath = path
        binding.remoteRevision =
          repositorySHA?.trimmedForPublishing.nilIfEmpty
          ?? binding.remoteRevision
      }
      repositoryBinding = binding
      return
    }

    repositoryBinding = DraftRepositoryBinding(
      identity: identity,
      repositoryPath: path,
      remoteRevision: repositorySHA,
      verification: .legacyUnverified,
      syncState: repositorySHA == nil ? .projectSaved : .synced
    )
  }

  public mutating func recordProjectFile(
    profile: SiteProfile,
    repositoryPath: String,
    renderedContentDigest: String
  ) {
    let normalizedPath = repositoryPath.normalizedRelativePath()
    let identity = DraftRepositoryIdentity(profile: profile)
    let canRetainRemoteRevision =
      repositoryBinding?.identity == identity
      && self.repositoryPath?.normalizedRelativePath() == normalizedPath
    let retainedRevision = canRetainRemoteRevision ? repositorySHA : nil
    let retainedImportFingerprint = canRetainRemoteRevision ? repositoryImportFingerprint : nil
    let retainedVerification =
      canRetainRemoteRevision
      ? (repositoryBinding?.verification ?? .legacyUnverified)
      : .legacyUnverified
    let recordedDigest =
      retainedRevision == nil
      ? renderedContentDigest
      : repositoryBinding?.renderedContentDigest
    let retainedPendingReviewDigest =
      canRetainRemoteRevision
      ? repositoryBinding?.pendingReviewContentDigest
      : nil
    let recordedSyncState: DraftRepositorySyncState
    if repositoryBinding?.syncState == .awaitingReview,
      let retainedPendingReviewDigest,
      retainedPendingReviewDigest == renderedContentDigest
    {
      recordedSyncState = .awaitingReview
    } else if retainedRevision == nil {
      recordedSyncState = .projectSaved
    } else if recordedDigest == renderedContentDigest {
      // Startup reconciliation and explicit writes of identical bytes do not
      // create a local change relative to the confirmed remote baseline.
      recordedSyncState = .synced
    } else {
      recordedSyncState = .localChanged
    }
    self.repositoryPath = normalizedPath
    repositorySHA = retainedRevision
    repositoryImportFingerprint = retainedImportFingerprint
    repositoryBinding = DraftRepositoryBinding(
      identity: identity,
      repositoryPath: normalizedPath,
      remoteRevision: retainedRevision,
      renderedContentDigest: recordedDigest,
      projectFileContentDigest: renderedContentDigest,
      pendingReviewContentDigest: recordedSyncState == .awaitingReview
        ? retainedPendingReviewDigest
        : nil,
      verification: retainedVerification,
      syncState: recordedSyncState,
      verifiedAt: canRetainRemoteRevision ? repositoryBinding?.verifiedAt : nil
    )
  }

  public mutating func confirmRepositoryBinding(
    profile: SiteProfile,
    repositoryPath: String,
    remoteRevision: String,
    renderedContentDigest: String,
    verifiedAt: Date = Date()
  ) {
    let normalizedPath = repositoryPath.normalizedRelativePath()
    let normalizedRevision = remoteRevision.trimmedForPublishing
    self.repositoryPath = normalizedPath
    repositorySHA = normalizedRevision
    repositoryImportFingerprint = repositoryContentFingerprint
    repositoryBinding = DraftRepositoryBinding(
      identity: DraftRepositoryIdentity(profile: profile),
      repositoryPath: normalizedPath,
      remoteRevision: normalizedRevision,
      renderedContentDigest: renderedContentDigest,
      projectFileContentDigest: renderedContentDigest,
      verification: .verified,
      syncState: .synced,
      verifiedAt: verifiedAt
    )
  }

  /// Records an explicitly reviewed remote baseline while preserving a local
  /// document that may still need publication. This is the atomic state used
  /// after visual conflict resolution; it never pretends a merged/local
  /// document is already present on the target branch.
  public mutating func adoptReviewedRemoteBaseline(
    profile: SiteProfile,
    repositoryPath: String,
    remoteRevision: String,
    remoteDocument: String,
    localDocument: String,
    verifiedAt: Date = Date()
  ) {
    let normalizedPath = repositoryPath.normalizedRelativePath()
    let normalizedRevision = remoteRevision.trimmedForPublishing
    let remoteDigest = Self.repositoryDocumentDigest(remoteDocument)
    let localDigest = Self.repositoryDocumentDigest(localDocument)
    let isSynced = remoteDigest == localDigest
    self.repositoryPath = normalizedPath
    repositorySHA = normalizedRevision
    repositoryBinding = DraftRepositoryBinding(
      identity: DraftRepositoryIdentity(profile: profile),
      repositoryPath: normalizedPath,
      remoteRevision: normalizedRevision,
      renderedContentDigest: remoteDigest,
      projectFileContentDigest: nil,
      verification: .verified,
      syncState: isSynced ? .synced : .localChanged,
      verifiedAt: verifiedAt
    )
    repositoryImportFingerprint = isSynced ? repositoryContentFingerprint : nil
  }

  public mutating func markRepositorySyncState(_ state: DraftRepositorySyncState) {
    guard var binding = repositoryBinding else { return }
    binding.syncState = state
    if state != .awaitingReview {
      binding.pendingReviewContentDigest = nil
    }
    repositoryBinding = binding
  }

  public mutating func markRepositoryAwaitingReview(profile: SiteProfile) {
    guard var binding = repositoryBinding else { return }
    binding.pendingReviewContentDigest = renderedRepositoryContentDigest(profile: profile)
    binding.syncState = .awaitingReview
    repositoryBinding = binding
  }

  public mutating func detachFromRepository() {
    repositoryPath = nil
    repositorySHA = nil
    repositoryImportFingerprint = nil
    repositoryBinding = nil
  }

  /// Editor bindings own content and workflow fields, never repository concurrency state.
  public mutating func preserveRepositoryState(from current: ArticleDraft) {
    repositoryPath = current.repositoryPath
    repositorySHA = current.repositorySHA
    repositoryImportFingerprint = current.repositoryImportFingerprint
    repositoryBinding = current.repositoryBinding
  }

  mutating func replaceRepositoryPathForProjection(_ path: String?) {
    repositoryPath = path?.normalizedRelativePath().nilIfEmpty
    guard var binding = repositoryBinding, let repositoryPath else {
      if path == nil { repositoryBinding = nil }
      return
    }
    binding.repositoryPath = repositoryPath
    repositoryBinding = binding
  }

  public func repositorySyncState(for profile: SiteProfile) -> DraftRepositorySyncState {
    guard let binding = repositoryBinding else { return .localOnly }
    guard binding.identity == nil || binding.identity == DraftRepositoryIdentity(profile: profile)
    else { return .diverged }
    switch binding.syncState {
    case .diverged, .failed:
      return binding.syncState
    case .awaitingReview:
      guard let pendingDigest = binding.pendingReviewContentDigest else {
        return .awaitingReview
      }
      return pendingDigest == renderedRepositoryContentDigest(profile: profile)
        ? .awaitingReview
        : .localChanged
    case .localOnly:
      return .localOnly
    case .projectSaved:
      return .projectSaved
    case .localChanged:
      // This state is set by a successful local project write while a remote
      // revision is retained. It is authoritative until a verified remote
      // operation establishes a new baseline.
      return .localChanged
    case .synced:
      guard binding.remoteRevision != nil else { return .projectSaved }
      guard let baseline = binding.renderedContentDigest else { return .localChanged }
      return baseline == renderedRepositoryContentDigest(profile: profile) ? .synced : .localChanged
    }
  }

  public func renderedRepositoryContentDigest(profile: SiteProfile) -> String {
    let document = FrontMatterRenderer().renderDocument(draft: self, profile: profile)
    return Self.repositoryDocumentDigest(document)
  }

  public static func repositoryDocumentDigest(_ document: String) -> String {
    SHA256.hash(data: Data(document.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func legacyRepositoryBinding(
    path: String?,
    remoteRevision: String?
  ) -> DraftRepositoryBinding? {
    guard let path = path?.normalizedRelativePath().nilIfEmpty else { return nil }
    return DraftRepositoryBinding(
      identity: nil,
      repositoryPath: path,
      remoteRevision: remoteRevision,
      verification: .legacyUnverified,
      syncState: remoteRevision == nil ? .projectSaved : .synced
    )
  }

  private static let fingerprintEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
  }()

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
      aliases: aliases,
      permalink: permalink,
      draft: draft,
      visibility: visibility,
      summary: summary,
      coverRepositoryPath: coverRepositoryPath,
      bodyMarkdown: bodyMarkdown,
      attachments:
        attachments
        .map(RepositoryAttachmentFingerprintSnapshot.init)
        .sorted { lhs, rhs in
          if lhs.repositoryPath == rhs.repositoryPath {
            return lhs.relativePublishPath < rhs.relativePublishPath
          }
          return lhs.repositoryPath < rhs.repositoryPath
        },
      status: status
    )
    guard let data = try? Self.fingerprintEncoder.encode(snapshot) else {
      assertionFailure("Failed to encode RepositoryContentFingerprintSnapshot")
      let fallback =
        "\(id.uuidString):\(title):\(date.timeIntervalSince1970):\(bodyMarkdown.utf8.count)"
      return SHA256.hash(data: Data(fallback.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  /// Advances only the general content timestamp. Prefer
  /// `markMetadataUpdated` or `markBodyUpdated` when the mutation kind is
  /// known so list ordering and editor concurrency remain explicit.
  public mutating func touch() {
    markBodyUpdated()
  }

}

private struct RepositoryContentFingerprintSnapshot: Encodable {
  var title: String
  var date: Date
  var slug: String
  var tags: [String]
  var categories: [String]
  var authors: [String]
  var aliases: [String]
  var permalink: String?
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
