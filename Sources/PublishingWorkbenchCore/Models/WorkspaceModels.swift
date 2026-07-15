import Foundation

public enum WorkspaceSection: String, CaseIterable, Codable, Identifiable, Sendable {
  case writing
  case siteStarter
  case sync
  case images
  case contentHealth
  case ai
  case generalDrafts
  case maintenance
  case releaseHistory

  public var id: String { rawValue }

  public var localizationKey: String {
    "workspace.\(rawValue)"
  }

  public var displayNameLocalizationKey: String {
    localizationKey
  }

  public var detailLocalizationKey: String {
    "\(localizationKey).detail"
  }

  public var systemImage: String {
    switch self {
    case .writing:
      return "square.and.pencil"
    case .siteStarter:
      return "sparkles.rectangle.stack"
    case .ai:
      return "sparkles"
    case .sync:
      return "arrow.triangle.2.circlepath"
    case .contentHealth:
      return "checklist"
    case .generalDrafts:
      return "shippingbox"
    case .maintenance:
      return "wrench.and.screwdriver"
    case .images:
      return "photo.on.rectangle"
    case .releaseHistory:
      return "clock.arrow.circlepath"
    }
  }

  public var keyboardShortcutKey: Character {
    switch self {
    case .writing:
      return "1"
    case .siteStarter:
      return "2"
    case .sync:
      return "3"
    case .images:
      return "4"
    case .contentHealth:
      return "5"
    case .ai:
      return "6"
    case .generalDrafts:
      return "7"
    case .maintenance:
      return "8"
    case .releaseHistory:
      return "9"
    }
  }

  public var keyboardShortcutLabel: String {
    "⌘\(keyboardShortcutKey)"
  }
}

public enum WorkspaceArea: String, CaseIterable, Identifiable, Sendable {
  case writing
  case publishing
  case site

  public var id: String { rawValue }

  public var localizationKey: String {
    "workspace.area.\(rawValue)"
  }

  public var systemImage: String {
    switch self {
    case .writing:
      return "square.and.pencil"
    case .publishing:
      return "paperplane"
    case .site:
      return "globe"
    }
  }

  public var sections: [WorkspaceSection] {
    switch self {
    case .writing:
      return [.writing, .ai, .images, .generalDrafts]
    case .publishing:
      return [.sync, .contentHealth, .releaseHistory]
    case .site:
      return [.siteStarter, .maintenance]
    }
  }

  public var defaultSection: WorkspaceSection {
    switch self {
    case .writing:
      return .writing
    case .publishing:
      return .sync
    case .site:
      return .siteStarter
    }
  }
}

public extension WorkspaceSection {
  var area: WorkspaceArea {
    switch self {
    case .writing, .ai, .images, .generalDrafts:
      return .writing
    case .sync, .contentHealth, .releaseHistory:
      return .publishing
    case .siteStarter, .maintenance:
      return .site
    }
  }
}

public enum WorkspaceNavigationSurface: String, CaseIterable, Sendable {
  case topBar
  case commandMenu
  case sidebarList
}

public enum WorkspaceContextSidebarMode: String, Sendable {
  case writingDrafts
  case contentHealthFilters
  case repositoryStages
  case none
}

public enum WorkspaceCenterSurface: String, CaseIterable, Sendable {
  case editor
  case siteStarter
  case repository
  case images
  case contentHealth
  case aiChat
  case generalDrafts
  case maintenance
  case releaseHistory
}

public extension WorkspaceSection {
  var centerSurface: WorkspaceCenterSurface {
    switch self {
    case .writing: .editor
    case .siteStarter: .siteStarter
    case .sync: .repository
    case .images: .images
    case .contentHealth: .contentHealth
    case .ai: .aiChat
    case .generalDrafts: .generalDrafts
    case .maintenance: .maintenance
    case .releaseHistory: .releaseHistory
    }
  }

  var requiresEditableDraftForCenterSurface: Bool {
    switch centerSurface {
    case .siteStarter, .aiChat, .generalDrafts, .maintenance:
      false
    case .editor, .repository, .images, .contentHealth, .releaseHistory:
      true
    }
  }
}

public extension WorkspaceSection {
  var contextSidebarMode: WorkspaceContextSidebarMode {
    switch self {
    case .writing:
      return .writingDrafts
    case .contentHealth:
      return .contentHealthFilters
    case .sync:
      return .repositoryStages
    case .siteStarter,
         .images,
         .ai,
         .generalDrafts,
         .maintenance,
         .releaseHistory:
      return .none
    }
  }
}

public struct WorkspaceNavigationItem: Identifiable, Hashable, Sendable {
  public var id: WorkspaceSection { section }
  public let section: WorkspaceSection
  public let displayNameLocalizationKey: String
  public let detailLocalizationKey: String
  public let systemImage: String
  public let keyboardShortcutKey: Character

  public var keyboardShortcutLabel: String {
    "⌘\(keyboardShortcutKey)"
  }

  public init(section: WorkspaceSection) {
    self.section = section
    self.displayNameLocalizationKey = section.displayNameLocalizationKey
    self.detailLocalizationKey = section.detailLocalizationKey
    self.systemImage = section.systemImage
    self.keyboardShortcutKey = section.keyboardShortcutKey
  }
}

public enum WorkspaceVisibilityPolicy {
  public static let hiddenNavigationSections: [WorkspaceSection] = [
    .maintenance,
    .releaseHistory,
  ]

  public static let dailyTopBarSections = WorkspaceSection.allCases.filter { section in
    section != .writing
      && section != .ai
      && section != .siteStarter
      && section != .generalDrafts
      && !hiddenNavigationSections.contains(section)
  }

  public static let commandMenuPrimarySections = WorkspaceSection.allCases.filter { section in
    section != .ai
      && section != .siteStarter
      && section != .generalDrafts
      && !hiddenNavigationSections.contains(section)
  }

  public static let secondaryEntrySections: [WorkspaceSection] = [
    .siteStarter,
    .generalDrafts,
  ]

}

public enum WorkspaceNavigationPresentation {
  public static let defaultSection: WorkspaceSection = .writing
  public static let primaryAreas = WorkspaceArea.allCases.filter { !primarySections(in: $0).isEmpty }
  public static let topBarItems = items(for: .topBar)
  public static let commandMenuItems = items(for: .commandMenu)
  public static let secondaryEntryItems = WorkspaceVisibilityPolicy.secondaryEntrySections.map(WorkspaceNavigationItem.init(section:))

  public static func primarySections(in area: WorkspaceArea) -> [WorkspaceSection] {
    area.sections.filter {
      !WorkspaceVisibilityPolicy.secondaryEntrySections.contains($0)
        && !WorkspaceVisibilityPolicy.hiddenNavigationSections.contains($0)
    }
  }

  public static func sections(for surface: WorkspaceNavigationSurface) -> [WorkspaceSection] {
    switch surface {
    case .topBar:
      return WorkspaceVisibilityPolicy.dailyTopBarSections
    case .commandMenu:
      return WorkspaceVisibilityPolicy.commandMenuPrimarySections
    case .sidebarList:
      return []
    }
  }

  public static func items(for surface: WorkspaceNavigationSurface) -> [WorkspaceNavigationItem] {
    sections(for: surface).map(WorkspaceNavigationItem.init(section:))
  }
}

public enum EditorDisplayMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case edit
  case preview
  case split

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .edit:
      return "编辑"
    case .preview:
      return "预览"
    case .split:
      return "分屏"
    }
  }

  public var systemImage: String {
    switch self {
    case .edit:
      return "square.and.pencil"
    case .preview:
      return "doc.richtext"
    case .split:
      return "rectangle.split.2x1"
    }
  }
}

public struct EditorFocusRequest: Identifiable, Equatable, Sendable {
  public var id: UUID
  public var draftID: UUID
  public var field: String?
  public var query: String?

  public init(
    id: UUID = UUID(),
    draftID: UUID,
    field: String?,
    query: String? = nil
  ) {
    self.id = id
    self.draftID = draftID
    self.field = field
    self.query = query
  }
}

public struct ActiveEditorSelection: Equatable, Sendable {
  public var draftID: UUID
  public var range: NSRange
  public var selectedText: String
  public var bodyUTF16Count: Int

  public init(
    draftID: UUID,
    range: NSRange,
    selectedText: String,
    bodyUTF16Count: Int
  ) {
    self.draftID = draftID
    self.range = range
    self.selectedText = selectedText
    self.bodyUTF16Count = bodyUTF16Count
  }

  public var hasSelectedText: Bool {
    range.length > 0 && !selectedText.trimmedForPublishing.isEmpty
  }

  public func validatedRange(in draft: ArticleDraft) -> NSRange? {
    guard draft.id == draftID, hasSelectedText else {
      return nil
    }
    let source = draft.bodyMarkdown as NSString
    guard bodyUTF16Count == source.length,
          range.location >= 0,
          range.length > 0,
          range.location + range.length <= source.length
    else {
      return nil
    }
    guard source.substring(with: range) == selectedText else {
      return nil
    }
    return range
  }
}

public struct DraftComparisonContent: Hashable, Sendable {
  public var repositoryPath: String
  public var localContent: String?
  public var remoteRefName: String?
  public var remoteContent: String?

  public init(
    repositoryPath: String,
    localContent: String?,
    remoteRefName: String? = nil,
    remoteContent: String? = nil
  ) {
    self.repositoryPath = repositoryPath
    self.localContent = localContent
    self.remoteRefName = remoteRefName
    self.remoteContent = remoteContent
  }

  public var preferredTitle: String {
    if let remoteRefName, remoteContent != nil {
      return "\(remoteRefName) 远端版本"
    }
    if localContent != nil {
      return "本地仓库已有版本"
    }
    return "未找到仓库版本"
  }

  public var preferredContent: String? {
    remoteContent ?? localContent
  }
}

public enum ReleaseRecordKind: String, CaseIterable, Codable, Identifiable, Sendable {
  case localWrite
  case batchLocalWrite
  case directCommit
  case reviewBranch
  case remoteDirectCommit
  case remoteReviewRequest
  case remotePublishFailure
  case remoteRollback
  case remoteReviewWithdrawal

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .localWrite:
      return "写入仓库"
    case .batchLocalWrite:
      return "批量写入"
    case .directCommit:
      return "直接提交"
    case .reviewBranch:
      return "发布分支"
    case .remoteDirectCommit:
      return "线上提交"
    case .remoteReviewRequest:
      return "线上 PR/MR"
    case .remotePublishFailure:
      return "线上发布失败"
    case .remoteRollback:
      return "线上回滚"
    case .remoteReviewWithdrawal:
      return "线上 Review 撤回"
    }
  }

  public var systemImage: String {
    switch self {
    case .localWrite:
      return "square.and.arrow.down"
    case .batchLocalWrite:
      return "square.stack.3d.down.right"
    case .directCommit:
      return "checkmark.seal"
    case .reviewBranch:
      return "arrow.triangle.branch"
    case .remoteDirectCommit:
      return "network"
    case .remoteReviewRequest:
      return "arrow.up.forward.app"
    case .remotePublishFailure:
      return "xmark.icloud"
    case .remoteRollback:
      return "arrow.uturn.backward.circle"
    case .remoteReviewWithdrawal:
      return "arrow.down.forward.and.arrow.up.backward.circle"
    }
  }
}

public struct ReleaseRecordBatchItem: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID { draftID }
  public var draftID: UUID
  public var draftTitle: String
  public var markdownPath: String
  public var changedPaths: [String]

  public init(
    draftID: UUID,
    draftTitle: String,
    markdownPath: String,
    changedPaths: [String]
  ) {
    self.draftID = draftID
    self.draftTitle = draftTitle
    self.markdownPath = markdownPath
    self.changedPaths = changedPaths
  }

  public init(
    planItem: BatchPublishPlanItem,
    changedPaths: [String]? = nil
  ) {
    let itemPaths = planItem.package.files.map(\.repositoryPath)
    let matchedChangedPaths = changedPaths?.filter { itemPaths.contains($0) } ?? []
    self.init(
      draftID: planItem.draftID,
      draftTitle: planItem.draftTitle,
      markdownPath: planItem.markdownPath,
      changedPaths: matchedChangedPaths.isEmpty ? itemPaths : matchedChangedPaths
    )
  }
}

public struct ReleaseRecord: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var kind: ReleaseRecordKind
  public var title: String
  public var summary: String
  public var siteProfileID: UUID?
  public var siteName: String?
  public var draftID: UUID?
  public var draftTitle: String?
  public var draftSummary: String?
  public var draftCoverAltText: String?
  public var markdownPath: String?
  public var changedPaths: [String]
  public var repositoryProvider: RepositoryProvider?
  public var repositoryBaseURL: String?
  public var repoOwner: String?
  public var repoName: String?
  public var branchName: String?
  public var targetBranch: String?
  public var commitSHA: String?
  public var reviewURL: String?
  public var reviewTitle: String?
  public var batchItems: [ReleaseRecordBatchItem]
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    kind: ReleaseRecordKind = .localWrite,
    title: String,
    summary: String,
    siteProfileID: UUID? = nil,
    siteName: String? = nil,
    draftID: UUID? = nil,
    draftTitle: String? = nil,
    draftSummary: String? = nil,
    draftCoverAltText: String? = nil,
    markdownPath: String? = nil,
    changedPaths: [String] = [],
    repositoryProvider: RepositoryProvider? = nil,
    repositoryBaseURL: String? = nil,
    repoOwner: String? = nil,
    repoName: String? = nil,
    branchName: String? = nil,
    targetBranch: String? = nil,
    commitSHA: String? = nil,
    reviewURL: String? = nil,
    reviewTitle: String? = nil,
    batchItems: [ReleaseRecordBatchItem] = [],
    createdAt: Date = Date()
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.summary = summary
    self.siteProfileID = siteProfileID
    self.siteName = siteName
    self.draftID = draftID
    self.draftTitle = draftTitle
    self.draftSummary = draftSummary
    self.draftCoverAltText = draftCoverAltText
    self.markdownPath = markdownPath
    self.changedPaths = changedPaths
    self.repositoryProvider = repositoryProvider
    self.repositoryBaseURL = repositoryBaseURL
    self.repoOwner = repoOwner
    self.repoName = repoName
    self.branchName = branchName
    self.targetBranch = targetBranch
    self.commitSHA = commitSHA
    self.reviewURL = reviewURL
    self.reviewTitle = reviewTitle
    self.batchItems = batchItems
    self.createdAt = createdAt
  }

  public var shortCommitSHA: String? {
    commitSHA.map { String($0.prefix(8)) }
  }

  public var reviewWebURL: URL? {
    reviewURL.flatMap(URL.init(string:))
  }

  public static func localWrite(
    package: PublishPackage,
    profile: SiteProfile,
    writtenPaths: [String],
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    ReleaseRecord(
      kind: .localWrite,
      title: "写入本地仓库：\(package.title)",
      summary: "已写入 \(writtenPaths.count) 个文件到工作树。",
      siteProfileID: profile.id,
      siteName: profile.name,
      draftID: package.draftID,
      draftTitle: package.title,
      draftSummary: package.draftSummary,
      draftCoverAltText: package.draftCoverAltText,
      markdownPath: package.markdownPath,
      changedPaths: writtenPaths,
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      createdAt: createdAt
    )
  }

  public static func batchLocalWrite(
    profile: SiteProfile,
    items: [BatchPublishPlanItem],
    writtenPaths: [String],
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    ReleaseRecord(
      kind: .batchLocalWrite,
      title: "批量写入本地仓库：\(profile.name)",
      summary: "已写入 \(items.count) 篇文章、\(writtenPaths.count) 个文件到工作树。",
      siteProfileID: profile.id,
      siteName: profile.name,
      changedPaths: writtenPaths,
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      batchItems: items.map { ReleaseRecordBatchItem(planItem: $0, changedPaths: writtenPaths) },
      createdAt: createdAt
    )
  }

  public static func gitPublish(
    package: PublishPackage,
    profile: SiteProfile,
    result: LocalGitPublishResult,
    reviewDraft: RemoteReviewDraft,
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    let kind: ReleaseRecordKind = result.mode == .reviewBranch ? .reviewBranch : .directCommit
    return ReleaseRecord(
      kind: kind,
      title: "\(kind.displayName)：\(package.title)",
      summary: "\(result.branchName) · \(result.committedPaths.count) 个文件 · \(String(result.commitSHA.prefix(8)))",
      siteProfileID: profile.id,
      siteName: profile.name,
      draftID: package.draftID,
      draftTitle: package.title,
      draftSummary: package.draftSummary,
      draftCoverAltText: package.draftCoverAltText,
      markdownPath: package.markdownPath,
      changedPaths: result.committedPaths,
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: result.branchName,
      targetBranch: reviewDraft.targetBranch,
      commitSHA: result.commitSHA,
      reviewURL: kind == .reviewBranch ? reviewDraft.webURL?.absoluteString : nil,
      reviewTitle: kind == .reviewBranch ? reviewDraft.title : nil,
      createdAt: createdAt
    )
  }

  public static func remotePublish(
    package: PublishPackage,
    profile: SiteProfile,
    result: RemoteRepositoryPublishResult,
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    let kind: ReleaseRecordKind = result.mode == .reviewRequest ? .remoteReviewRequest : .remoteDirectCommit
    return ReleaseRecord(
      kind: kind,
      title: "\(kind.displayName)：\(package.title)",
      summary: "\(result.provider.displayName) · \(result.branchName) · \(result.changedPaths.count) 个文件"
        + (result.commitSHA.map { " · \(String($0.prefix(8)))" } ?? ""),
      siteProfileID: profile.id,
      siteName: profile.name,
      draftID: package.draftID,
      draftTitle: package.title,
      draftSummary: package.draftSummary,
      draftCoverAltText: package.draftCoverAltText,
      markdownPath: package.markdownPath,
      changedPaths: result.changedPaths,
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: result.branchName,
      targetBranch: result.targetBranch,
      commitSHA: result.commitSHA,
      reviewURL: result.reviewURL,
      reviewTitle: result.reviewTitle,
      createdAt: createdAt
    )
  }

  public static func batchRemotePublish(
    profile: SiteProfile,
    items: [BatchPublishPlanItem],
    result: RemoteRepositoryPublishResult,
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    let kind: ReleaseRecordKind = result.mode == .reviewRequest ? .remoteReviewRequest : .remoteDirectCommit
    return ReleaseRecord(
      kind: kind,
      title: "批量\(kind.displayName)：\(profile.name)",
      summary: "\(result.provider.displayName) · \(items.count) 篇文章 · \(result.changedPaths.count) 个文件"
        + (result.commitSHA.map { " · \(String($0.prefix(8)))" } ?? ""),
      siteProfileID: profile.id,
      siteName: profile.name,
      changedPaths: result.changedPaths,
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: result.branchName,
      targetBranch: result.targetBranch,
      commitSHA: result.commitSHA,
      reviewURL: result.reviewURL,
      reviewTitle: result.reviewTitle,
      batchItems: items.map { ReleaseRecordBatchItem(planItem: $0, changedPaths: result.changedPaths) },
      createdAt: createdAt
    )
  }

  public static func remotePublishFailure(
    package: PublishPackage,
    profile: SiteProfile,
    mode: RemoteRepositoryPublishMode,
    errorMessage: String,
    changedPaths: [String]? = nil,
    commitSHA: String? = nil,
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    ReleaseRecord(
      kind: .remotePublishFailure,
      title: "\(mode.displayName)失败：\(package.title)",
      summary: errorMessage,
      siteProfileID: profile.id,
      siteName: profile.name,
      draftID: package.draftID,
      draftTitle: package.title,
      draftSummary: package.draftSummary,
      draftCoverAltText: package.draftCoverAltText,
      markdownPath: package.markdownPath,
      changedPaths: changedPaths ?? package.files.map(\.repositoryPath),
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: mode == .reviewRequest ? package.reviewBranchName : (profile.branch.nilIfEmpty ?? "main"),
      targetBranch: profile.branch.nilIfEmpty ?? "main",
      commitSHA: commitSHA,
      createdAt: createdAt
    )
  }

  public static func batchRemotePublishFailure(
    package: PublishPackage,
    profile: SiteProfile,
    items: [BatchPublishPlanItem],
    mode: RemoteRepositoryPublishMode,
    errorMessage: String,
    changedPaths: [String]? = nil,
    commitSHA: String? = nil,
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    ReleaseRecord(
      kind: .remotePublishFailure,
      title: "批量\(mode.displayName)失败：\(profile.name)",
      summary: "\(items.count) 篇文章未完成线上发布：\(errorMessage)",
      siteProfileID: profile.id,
      siteName: profile.name,
      changedPaths: changedPaths ?? package.files.map(\.repositoryPath),
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: mode == .reviewRequest ? package.reviewBranchName : (profile.branch.nilIfEmpty ?? "main"),
      targetBranch: profile.branch.nilIfEmpty ?? "main",
      commitSHA: commitSHA,
      batchItems: items.map {
        ReleaseRecordBatchItem(planItem: $0, changedPaths: changedPaths ?? package.files.map(\.repositoryPath))
      },
      createdAt: createdAt
    )
  }

  public static func remoteRollback(
    original: ReleaseRecord,
    profile: SiteProfile,
    result: RemoteRepositoryRollbackResult,
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    ReleaseRecord(
      kind: .remoteRollback,
      title: "线上回滚：\(original.draftTitle ?? original.title)",
      summary: "\(result.provider.displayName) · \(result.targetBranch) · 回滚 \(String(result.rolledBackCommitSHA.prefix(8))) -> \(String(result.rollbackCommitSHA.prefix(8)))",
      siteProfileID: profile.id,
      siteName: profile.name,
      draftID: original.draftID,
      draftTitle: original.draftTitle,
      draftSummary: original.draftSummary,
      draftCoverAltText: original.draftCoverAltText,
      markdownPath: original.markdownPath,
      changedPaths: result.changedPaths,
      repositoryProvider: result.provider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: result.targetBranch,
      targetBranch: result.targetBranch,
      commitSHA: result.rollbackCommitSHA,
      reviewURL: result.remoteURL,
      reviewTitle: "Rollback \(original.draftTitle ?? original.title)",
      batchItems: original.batchItems,
      createdAt: createdAt
    )
  }

  public static func remoteReviewWithdrawal(
    original: ReleaseRecord,
    profile: SiteProfile,
    result: RemoteRepositoryReviewWithdrawalResult,
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    ReleaseRecord(
      kind: .remoteReviewWithdrawal,
      title: "线上 Review 撤回：\(original.draftTitle ?? original.title)",
      summary: "\(result.provider.displayName) · #\(result.reviewNumber) · \(result.state)",
      siteProfileID: profile.id,
      siteName: profile.name,
      draftID: original.draftID,
      draftTitle: original.draftTitle,
      draftSummary: original.draftSummary,
      draftCoverAltText: original.draftCoverAltText,
      markdownPath: original.markdownPath,
      changedPaths: original.changedPaths,
      repositoryProvider: result.provider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: result.branchName,
      targetBranch: result.targetBranch,
      commitSHA: original.commitSHA,
      reviewURL: result.reviewURL,
      reviewTitle: "Closed \(original.reviewTitle ?? original.draftTitle ?? original.title)",
      batchItems: original.batchItems,
      createdAt: createdAt
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case kind
    case title
    case summary
    case siteProfileID
    case siteName
    case draftID
    case draftTitle
    case draftSummary
    case draftCoverAltText
    case markdownPath
    case changedPaths
    case repositoryProvider
    case repositoryBaseURL
    case repoOwner
    case repoName
    case branchName
    case targetBranch
    case commitSHA
    case reviewURL
    case reviewTitle
    case batchItems
    case createdAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    kind = try container.decodeIfPresent(ReleaseRecordKind.self, forKey: .kind) ?? .localWrite
    title = try container.decode(String.self, forKey: .title)
    summary = try container.decode(String.self, forKey: .summary)
    siteProfileID = try container.decodeIfPresent(UUID.self, forKey: .siteProfileID)
    siteName = try container.decodeIfPresent(String.self, forKey: .siteName)
    draftID = try container.decodeIfPresent(UUID.self, forKey: .draftID)
    draftTitle = try container.decodeIfPresent(String.self, forKey: .draftTitle)
    draftSummary = try container.decodeIfPresent(String.self, forKey: .draftSummary)
    draftCoverAltText = try container.decodeIfPresent(String.self, forKey: .draftCoverAltText)
    markdownPath = try container.decodeIfPresent(String.self, forKey: .markdownPath)
    changedPaths = try container.decodeIfPresent([String].self, forKey: .changedPaths) ?? []
    repositoryProvider = try container.decodeIfPresent(RepositoryProvider.self, forKey: .repositoryProvider)
    repositoryBaseURL = try container.decodeIfPresent(String.self, forKey: .repositoryBaseURL)
    repoOwner = try container.decodeIfPresent(String.self, forKey: .repoOwner)
    repoName = try container.decodeIfPresent(String.self, forKey: .repoName)
    branchName = try container.decodeIfPresent(String.self, forKey: .branchName)
    targetBranch = try container.decodeIfPresent(String.self, forKey: .targetBranch)
    commitSHA = try container.decodeIfPresent(String.self, forKey: .commitSHA)
    reviewURL = try container.decodeIfPresent(String.self, forKey: .reviewURL)
    reviewTitle = try container.decodeIfPresent(String.self, forKey: .reviewTitle)
    batchItems = try container.decodeIfPresent([ReleaseRecordBatchItem].self, forKey: .batchItems) ?? []
    createdAt = try container.decode(Date.self, forKey: .createdAt)
  }
}
