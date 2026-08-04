import Foundation
import os

private let logger = Logger(subsystem: "com.repopress", category: "BatchPublishPlanService")

public enum BatchPublishReadiness: String, CaseIterable, Codable, Sendable {
  case ready
  case needsReview
  case blocked
  case unchanged

  public var displayName: String {
    switch self {
    case .ready:
      return "可写入"
    case .needsReview:
      return "需确认"
    case .blocked:
      return "已阻塞"
    case .unchanged:
      return "无变化"
    }
  }

  public var systemImage: String {
    switch self {
    case .ready:
      return "checkmark.circle"
    case .needsReview:
      return "exclamationmark.triangle"
    case .blocked:
      return "xmark.octagon"
    case .unchanged:
      return "equal.circle"
    }
  }
}

public struct BatchPublishPlanItem: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID { draftID }
  public var draftID: UUID
  public var draftTitle: String
  public var markdownPath: String
  public var readiness: BatchPublishReadiness
  public var package: PublishPackage
  public var preview: LocalPublishPreview
  public var preflightIssues: [PreflightIssue]

  public init(
    draftID: UUID,
    draftTitle: String,
    markdownPath: String,
    readiness: BatchPublishReadiness,
    package: PublishPackage,
    preview: LocalPublishPreview,
    preflightIssues: [PreflightIssue]
  ) {
    self.draftID = draftID
    self.draftTitle = draftTitle
    self.markdownPath = markdownPath
    self.readiness = readiness
    self.package = package
    self.preview = preview
    self.preflightIssues = preflightIssues
  }

  public var allIssues: [PreflightIssue] {
    preflightIssues + preview.issues
  }

  public var errorCount: Int {
    allIssues.filter { $0.severity == .error }.count
  }

  public var warningCount: Int {
    allIssues.filter { $0.severity == .warning }.count
  }

  public var changedFileCount: Int {
    preview.changedFileDiffs.count
  }

  public var fileCount: Int {
    package.files.count
  }

  public var imageFileCount: Int {
    package.files.filter { $0.kind == .image }.count
  }

  public var totalByteSize: Int64 {
    package.files.reduce(0) { $0 + $1.byteSize }
  }

  public var isWritable: Bool {
    readiness == .ready && changedFileCount > 0
  }
}

public struct BatchPublishPlan: Codable, Hashable, Sendable {
  public var profileID: UUID
  public var siteName: String
  public var items: [BatchPublishPlanItem]
  public var generatedAt: Date

  public init(
    profileID: UUID,
    siteName: String,
    items: [BatchPublishPlanItem],
    generatedAt: Date = Date()
  ) {
    self.profileID = profileID
    self.siteName = siteName
    self.items = items
    self.generatedAt = generatedAt
  }

  public var readyCount: Int {
    items.filter { $0.readiness == .ready }.count
  }

  public var needsReviewCount: Int {
    items.filter { $0.readiness == .needsReview }.count
  }

  public var blockedCount: Int {
    items.filter { $0.readiness == .blocked }.count
  }

  public var unchangedCount: Int {
    items.filter { $0.readiness == .unchanged }.count
  }

  public var writableItems: [BatchPublishPlanItem] {
    items.filter(\.isWritable)
  }

  public var remotePublishableItems: [BatchPublishPlanItem] {
    items.filter { item in
      item.readiness != .blocked && item.changedFileCount > 0
    }
  }

  public var changedFileCount: Int {
    items.reduce(0) { $0 + $1.changedFileCount }
  }

  public var publishFileCount: Int {
    items.reduce(0) { $0 + $1.fileCount }
  }

  public var totalByteSize: Int64 {
    items.reduce(0) { $0 + $1.totalByteSize }
  }
}

public struct BatchLocalWriteResult: Codable, Hashable, Sendable {
  public var writtenDraftCount: Int
  public var writtenPaths: [String]
  public var failedTitles: [String]
  public var skippedCount: Int

  public init(
    writtenDraftCount: Int,
    writtenPaths: [String],
    failedTitles: [String] = [],
    skippedCount: Int = 0
  ) {
    self.writtenDraftCount = writtenDraftCount
    self.writtenPaths = writtenPaths
    self.failedTitles = failedTitles
    self.skippedCount = skippedCount
  }
}

public struct BatchPublishPlanService: Sendable {
  private let preflightService: PreflightCheckService
  private let publishPackageBuilder: PublishPackageBuilder
  private let localPublishPreviewService: LocalPublishPreviewService
  private let remotePublishRiskService: RemotePublishRiskService

  public init(
    preflightService: PreflightCheckService = PreflightCheckService(),
    publishPackageBuilder: PublishPackageBuilder = PublishPackageBuilder(),
    localPublishPreviewService: LocalPublishPreviewService = LocalPublishPreviewService(),
    remotePublishRiskService: RemotePublishRiskService = RemotePublishRiskService()
  ) {
    self.preflightService = preflightService
    self.publishPackageBuilder = publishPackageBuilder
    self.localPublishPreviewService = localPublishPreviewService
    self.remotePublishRiskService = remotePublishRiskService
  }

  public func plan(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    repositoryReport: RepositoryScanReport?
  ) -> BatchPublishPlan {
    var items = drafts.map { draft in
      let package = publishPackageBuilder.build(draft: draft, profile: profile)
      let preview = localPublishPreviewService.preview(package: package, profile: profile)
      var issues = preflightService.run(
        draft: draft,
        allDrafts: drafts,
        profile: profile,
        repositoryReport: repositoryReport
      )
      issues.append(contentsOf: remotePublishRiskService.issues(package: package, repositoryReport: repositoryReport))

      return BatchPublishPlanItem(
        draftID: draft.id,
        draftTitle: draft.title,
        markdownPath: package.markdownPath,
        readiness: readiness(preflightIssues: issues, preview: preview),
        package: package,
        preview: preview,
        preflightIssues: issues
      )
    }

    applyBatchDestinationConflicts(to: &items)

    return BatchPublishPlan(profileID: profile.id, siteName: profile.name, items: items)
  }

  public func planAsync(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    repositoryReport: RepositoryScanReport?
  ) async -> BatchPublishPlan {
    await Task.detached(priority: .userInitiated) {
      plan(drafts: drafts, profile: profile, repositoryReport: repositoryReport)
    }.value
  }

  private func applyBatchDestinationConflicts(to items: inout [BatchPublishPlanItem]) {
    var occurrencesByPath: [String: [(itemIndex: Int, file: PublishPackageFile)]] = [:]
    for (itemIndex, item) in items.enumerated() {
      for file in item.package.files {
        let path = file.repositoryPath.normalizedRelativePath()
        guard !path.isEmpty else { continue }
        occurrencesByPath[path, default: []].append((itemIndex, file))
      }
    }

    var conflictsByItemIndex: [Int: Set<String>] = [:]
    for (path, occurrences) in occurrencesByPath where occurrences.count > 1 {
      guard let first = occurrences.first else { continue }
      let payloadsMatch = occurrences.dropFirst().allSatisfy {
        publishFilesHaveEquivalentPayload(first.file, $0.file)
      }
      let expectedVersions = Set(
        occurrences.compactMap { $0.file.expectedRemoteSHA?.trimmedForPublishing.nilIfEmpty }
      )
      guard !payloadsMatch || expectedVersions.count > 1 else { continue }
      for occurrence in occurrences {
        conflictsByItemIndex[occurrence.itemIndex, default: []].insert(path)
      }
    }

    for (itemIndex, paths) in conflictsByItemIndex {
      let sortedPaths = paths.sorted()
      items[itemIndex].preflightIssues.append(
        PreflightIssue(
          severity: .error,
          title: CoreL10n.text("批量目标路径冲突"),
          message: CoreL10n.format(
            "以下路径被多个发布文件占用且内容或远端版本不一致：%@。",
            sortedPaths.joined(separator: "、")
          ),
          field: "attachments"
        )
      )
      items[itemIndex].readiness = .blocked
    }
  }

  private func publishFilesHaveEquivalentPayload(
    _ lhs: PublishPackageFile,
    _ rhs: PublishPackageFile
  ) -> Bool {
    guard lhs.kind == rhs.kind, lhs.operation == rhs.operation else { return false }
    if lhs.operation == .delete { return true }
    switch lhs.kind {
    case .markdown:
      return lhs.content == rhs.content
    case .image, .video:
      guard let lhsPath = lhs.sourceFilePath?.nilIfEmpty,
            let rhsPath = rhs.sourceFilePath?.nilIfEmpty else {
        return false
      }
      let lhsURL = URL(fileURLWithPath: lhsPath).standardizedFileURL
      let rhsURL = URL(fileURLWithPath: rhsPath).standardizedFileURL
      if lhsURL == rhsURL { return true }
      if lhs.byteSize > 0, rhs.byteSize > 0, lhs.byteSize != rhs.byteSize {
        return false
      }
      do {
        let lhsDigest = try BoundedFileReader.sha256(
          at: lhsURL,
          maximumByteCount: WorkbenchFileReadLimits.maximumRemoteMediaUploadByteCount
        )
        let rhsDigest = try BoundedFileReader.sha256(
          at: rhsURL,
          maximumByteCount: WorkbenchFileReadLimits.maximumRemoteMediaUploadByteCount
        )
        return lhsDigest == rhsDigest
      } catch {
        logger.warning("无法读取文件进行比较: \(error.localizedDescription, privacy: .public)")
        return false
      }
    }
  }

  private func readiness(
    preflightIssues: [PreflightIssue],
    preview: LocalPublishPreview
  ) -> BatchPublishReadiness {
    let hasError = (preflightIssues + preview.issues).contains { $0.severity == .error }
    let hasBlockingDiff = preview.fileDiffs.contains {
      $0.status == .missingSource || $0.status == .unsafePath
    }

    if hasError || hasBlockingDiff {
      return .blocked
    }

    if preview.changedFileDiffs.isEmpty {
      return .unchanged
    }

    let hasWarning = (preflightIssues + preview.issues).contains { $0.severity == .warning }
    return hasWarning ? .needsReview : .ready
  }
}

func deduplicatedBatchPublishFiles(_ files: [PublishPackageFile]) -> [PublishPackageFile] {
  var result: [PublishPackageFile] = []
  var indexByPath: [String: Int] = [:]
  for file in files {
    let path = file.repositoryPath.normalizedRelativePath()
    guard let existingIndex = indexByPath[path] else {
      indexByPath[path] = result.count
      result.append(file)
      continue
    }
    if result[existingIndex].expectedRemoteSHA?.trimmedForPublishing.nilIfEmpty == nil,
       let expectedRemoteSHA = file.expectedRemoteSHA?.trimmedForPublishing.nilIfEmpty {
      result[existingIndex].expectedRemoteSHA = expectedRemoteSHA
    }
  }
  return result
}
