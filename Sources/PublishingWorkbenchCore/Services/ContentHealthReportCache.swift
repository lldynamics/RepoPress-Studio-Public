import CryptoKit
import Foundation
import PublishingDomainContracts
import os

/// Lightweight observability for the in-memory content-health cache.
///
/// The cache is deliberately not persisted. A report can always be rebuilt from
/// the current drafts, profile, and source files when the process starts or when
/// an entry cannot be fingerprinted safely.
struct ContentHealthReportCacheStatistics: Equatable, Sendable {
  var hitCount: Int
  var missCount: Int
  var uncacheableCount: Int
  var entryCount: Int

  init(
    hitCount: Int = 0,
    missCount: Int = 0,
    uncacheableCount: Int = 0,
    entryCount: Int = 0
  ) {
    self.hitCount = hitCount
    self.missCount = missCount
    self.uncacheableCount = uncacheableCount
    self.entryCount = entryCount
  }
}

/// A bounded, thread-safe cache of per-article health summaries.
///
/// `ContentHealthReportService.reportAsync` runs in a detached task while the
/// synchronous API may be used by the store on its actor. The lock keeps the
/// mutable cache state safe across both call paths without making the report
/// service actor-isolated. Each draft keeps only its latest full health
/// fingerprint, so a stale entry is never returned merely because the draft ID
/// is unchanged and old profile/presentation variants do not accumulate.
final class ContentHealthReportCache: Sendable {
  static let defaultMaximumEntryCount = 512

  private struct Entry: Sendable {
    var key: ContentHealthReportCacheKey
    var summary: DraftPreflightSummary
    var lastAccess: UInt64
  }

  private struct State: Sendable {
    var entries: [UUID: Entry] = [:]
    var accessCounter: UInt64 = 0
    var hitCount = 0
    var missCount = 0
    var uncacheableCount = 0
  }

  private let maximumEntryCount: Int
  private let state: OSAllocatedUnfairLock<State>

  init(maximumEntryCount: Int = ContentHealthReportCache.defaultMaximumEntryCount) {
    self.maximumEntryCount = max(1, maximumEntryCount)
    self.state = OSAllocatedUnfairLock(initialState: State())
  }

  func prune(keepingDraftIDs draftIDs: Set<UUID>) {
    state.withLock { state in
      state.entries = state.entries.filter { draftIDs.contains($0.key) }
    }
  }

  func lookup(_ key: ContentHealthReportCacheKey?) -> DraftPreflightSummary? {
    state.withLock { state in
      guard let key else {
        state.uncacheableCount += 1
        state.missCount += 1
        return nil
      }

      guard var entry = state.entries[key.draftID], entry.key == key else {
        state.missCount += 1
        return nil
      }

      state.hitCount += 1
      state.accessCounter &+= 1
      entry.lastAccess = state.accessCounter
      state.entries[key.draftID] = entry
      return entry.summary
    }
  }

  func insert(_ summary: DraftPreflightSummary, for key: ContentHealthReportCacheKey) {
    state.withLock { state in
      state.accessCounter &+= 1
      state.entries[key.draftID] = Entry(
        key: key,
        summary: summary,
        lastAccess: state.accessCounter
      )
      evictIfNeeded(&state)
    }
  }

  var statistics: ContentHealthReportCacheStatistics {
    state.withLock { state in
      ContentHealthReportCacheStatistics(
        hitCount: state.hitCount,
        missCount: state.missCount,
        uncacheableCount: state.uncacheableCount,
        entryCount: state.entries.count
      )
    }
  }

  private func evictIfNeeded(_ state: inout State) {
    guard state.entries.count > maximumEntryCount else { return }
    let overflow = state.entries.count - maximumEntryCount
    let keysToRemove = state.entries
      .sorted { lhs, rhs in lhs.value.lastAccess < rhs.value.lastAccess }
      .prefix(overflow)
      .map(\.key)
    for key in keysToRemove {
      state.entries.removeValue(forKey: key)
    }
  }
}

struct ContentHealthReportCacheKey: Hashable, Sendable {
  let serviceNamespace: UUID
  let draftID: UUID
  let digest: String

  static func make(
    draft: ArticleDraft,
    profile: SiteProfile,
    presentation: ContentHealthDraftPresentation,
    hasDuplicateTitle: Bool,
    hasDuplicatePath: Bool,
    translationFreshness: ArticleTranslationFreshness?,
    serviceNamespace: UUID
  ) -> ContentHealthReportCacheKey? {
    // An unreadable source file may become readable (or be atomically replaced)
    // without changing the draft. Do not cache that article until metadata is
    // available, so a transient filesystem failure cannot produce a stale hit.
    var resourceMetadata: [ContentHealthResourceMetadataSnapshot] = []
    var hasUnreadableResource = false
    for attachment in draft.attachments where attachment.mediaKind == .image {
      guard let sourceFilePath = attachment.sourceFilePath else { continue }
      let metadata = LocalContentImportFileMetadata.read(
        from: URL(fileURLWithPath: sourceFilePath),
        includingContentSample: true
      )
      if metadata == nil {
        hasUnreadableResource = true
      }
      resourceMetadata.append(
        ContentHealthResourceMetadataSnapshot(
          path: sourceFilePath,
          metadata: metadata
        )
      )
    }

    let snapshot = ContentHealthReportFingerprintSnapshot(
      schemaVersion: 1,
      draft: ContentHealthDraftFingerprintSnapshot(draft: draft),
      profile: ContentHealthProfileFingerprintSnapshot(profile: profile),
      presentation: ContentHealthPresentationFingerprintSnapshot(presentation: presentation),
      hasDuplicateTitle: hasDuplicateTitle,
      hasDuplicatePath: hasDuplicatePath,
      translationFreshness: translationFreshness,
      futureDateWarningActive: draft.date > Date().addingTimeInterval(60),
      resourceMetadata: resourceMetadata
    )
    let data: Data
    do {
      data = try ContentHealthReportFingerprintSnapshot.encode(snapshot)
    } catch {
      return nil
    }

    let digest = Data(SHA256.hash(data: data)).base64EncodedString()
    if hasUnreadableResource {
      return nil
    }
    return ContentHealthReportCacheKey(
      serviceNamespace: serviceNamespace,
      draftID: draft.id,
      digest: digest
    )
  }
}

private struct ContentHealthReportFingerprintSnapshot: Encodable {
  static func encode(_ snapshot: Self) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(snapshot)
  }

  let schemaVersion: Int
  let draft: ContentHealthDraftFingerprintSnapshot
  let profile: ContentHealthProfileFingerprintSnapshot
  let presentation: ContentHealthPresentationFingerprintSnapshot
  let hasDuplicateTitle: Bool
  let hasDuplicatePath: Bool
  let translationFreshness: ArticleTranslationFreshness?
  let futureDateWarningActive: Bool
  let resourceMetadata: [ContentHealthResourceMetadataSnapshot]
}

private struct ContentHealthPresentationFingerprintSnapshot: Encodable {
  let title: String
  let markdownPath: String

  init(presentation: ContentHealthDraftPresentation) {
    title = presentation.title
    markdownPath = presentation.markdownPath
  }
}

private struct ContentHealthDraftFingerprintSnapshot: Encodable {
  let id: UUID
  let siteProfileID: UUID
  let title: String
  let date: Date
  let slug: String
  let tags: [String]
  let categories: [String]
  let authors: [String]
  let aliases: [String]
  let pendingSlugRedirectPaths: [String]
  let permalink: String?
  let draft: Bool
  let visibility: ArticleVisibility
  let summary: String
  let coverAttachmentID: UUID?
  let bodyMarkdown: String
  let attachments: [DraftAttachment]
  let status: DraftStatus
  let repositoryPath: String?

  init(draft: ArticleDraft) {
    id = draft.id
    siteProfileID = draft.siteProfileID
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
    bodyMarkdown = draft.bodyMarkdown
    attachments = draft.attachments
    status = draft.status
    repositoryPath = draft.repositoryPath
  }
}

private struct ContentHealthProfileFingerprintSnapshot: Encodable {
  let id: UUID
  let purpose: SiteProfilePurpose
  let siteKind: SiteKind
  let frontMatterStyle: FrontMatterStyle
  let contentRoot: String
  let assetRoot: String
  let markdownPathPattern: String
  let translationMarkdownPathPattern: String?
  let imagePathPattern: String
  let publicImagePathPattern: String
  let dateFormat: String
  let includeDraftFlagInFrontMatter: Bool
  let includeCoverInFrontMatter: Bool
  let slugValidationRule: SiteSlugValidationRule

  init(profile: SiteProfile) {
    id = profile.id
    purpose = profile.purpose
    siteKind = profile.siteKind
    frontMatterStyle = profile.frontMatterStyle
    contentRoot = profile.contentRoot
    assetRoot = profile.assetRoot
    markdownPathPattern = profile.markdownPathPattern
    translationMarkdownPathPattern = profile.translationMarkdownPathPattern
    imagePathPattern = profile.imagePathPattern
    publicImagePathPattern = profile.publicImagePathPattern
    dateFormat = profile.dateFormat
    includeDraftFlagInFrontMatter = profile.includeDraftFlagInFrontMatter
    includeCoverInFrontMatter = profile.includeCoverInFrontMatter
    slugValidationRule = profile.slugValidationRule
  }
}

private struct ContentHealthResourceMetadataSnapshot: Encodable {
  let path: String
  let metadata: LocalContentImportFileMetadata?
}
