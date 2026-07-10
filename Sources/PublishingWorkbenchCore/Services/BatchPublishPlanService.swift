import Foundation

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

public struct BatchPublishPlanService {
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
    let items = drafts.map { draft in
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

    return BatchPublishPlan(profileID: profile.id, siteName: profile.name, items: items)
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
