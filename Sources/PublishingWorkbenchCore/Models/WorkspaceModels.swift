import Foundation

public enum WorkspaceSection: String, CaseIterable, Codable, Identifiable, Sendable {
  case writing
  case library
  case rss
  case siteStarter
  case sync
  case images
  case contentHealth
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
    case .library:
      return "books.vertical"
    case .rss:
      return "dot.radiowaves.left.and.right"
    case .siteStarter:
      return "sparkles.rectangle.stack"
    case .sync:
      return "arrow.triangle.2.circlepath"
    case .contentHealth:
      return "checklist"
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
    case .library:
      return "2"
    case .rss:
      return "9"
    case .siteStarter:
      return "5"
    case .sync:
      return "3"
    case .images:
      return "6"
    case .contentHealth:
      return "4"
    case .maintenance:
      return "7"
    case .releaseHistory:
      return "8"
    }
  }

  public var keyboardShortcutLabel: String {
    "⌘\(keyboardShortcutKey)"
  }
}

public enum WorkspaceCenterSurface: String, CaseIterable, Sendable {
  case editor
  case knowledgeLibrary
  case rssReader
  case siteStarter
  case repository
  case images
  case contentHealth
}

public enum WorkspaceInspectorRoute: String, CaseIterable, Sendable {
  case articleMetadata
  case articleChecks
  case articleImages
  case repository
  case siteStarter
  case aiAssistant
  case unavailable
}

/// Keeps Inspector routing testable outside SwiftUI. Context-only subpages
/// such as maintenance and release history deliberately use their parent
/// workspace without opening a second Inspector surface.
public enum WorkspaceInspectorPresentation {
  /// Resolves the visible Inspector state without changing the user's stored
  /// preference while SwiftUI is measuring or rearranging the workspace.
  public static func isPresented(
    requested: Bool,
    supportsInspector: Bool,
    isFocusMode: Bool,
    allowsInspector: Bool = true
  ) -> Bool {
    requested && supportsInspector && !isFocusMode && allowsInspector
  }

  public static func route(
    for section: WorkspaceSection,
    isAIAssistantPresented: Bool = false,
    isRepositoryHistoryPresented: Bool = false,
    isMaintenancePresented: Bool = false
  ) -> WorkspaceInspectorRoute {
    if isAIAssistantPresented && section == .writing {
      return .aiAssistant
    }

    switch section {
    case .writing:
      return .articleMetadata
    case .library:
      return .unavailable
    case .rss:
      return .unavailable
    case .contentHealth:
      return isMaintenancePresented ? .unavailable : .articleChecks
    case .images:
      return .articleImages
    case .sync:
      return isRepositoryHistoryPresented ? .unavailable : .repository
    case .siteStarter:
      return .siteStarter
    case .maintenance, .releaseHistory:
      return .unavailable
    }
  }

  public static func supportsInspector(
    for section: WorkspaceSection,
    isAIAssistantPresented: Bool = false,
    isRepositoryHistoryPresented: Bool = false,
    isMaintenancePresented: Bool = false
  ) -> Bool {
    route(
      for: section,
      isAIAssistantPresented: isAIAssistantPresented,
      isRepositoryHistoryPresented: isRepositoryHistoryPresented,
      isMaintenancePresented: isMaintenancePresented
    ) != .unavailable
  }
}

public extension WorkspaceSection {
  var centerSurface: WorkspaceCenterSurface {
    switch self {
    case .writing: .editor
    case .library: .knowledgeLibrary
    case .rss: .rssReader
    case .siteStarter: .siteStarter
    case .sync: .repository
    case .images: .images
    case .contentHealth: .contentHealth
    case .maintenance: .contentHealth
    case .releaseHistory: .repository
    }
  }

  var requiresEditableDraftForCenterSurface: Bool {
    self == .writing
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

  /// Primary navigation is an explicit allowlist. New enum cases must never
  /// become user-facing merely because they were added to `WorkspaceSection`.
  public static let commandMenuPrimarySections: [WorkspaceSection] = [
    .writing,
    .library,
    .rss,
    .sync,
    .contentHealth,
  ]

  /// Feature workspaces reached from their owning primary workspace rather
  /// than presented as another top-level destination.
  public static let siteResourceSections: [WorkspaceSection] = [
    .images,
  ]

  public static let secondaryEntrySections: [WorkspaceSection] = [
    .siteStarter,
  ]

  /// Keep this independent from `allCases` and the advanced command menu.
  /// Advanced entries may be aliases or context-only routes that should not
  /// be discoverable as standalone command-palette workspaces.
  public static let commandPaletteSections: [WorkspaceSection] = [
    .writing,
    .library,
    .rss,
    .sync,
    .contentHealth,
    .siteStarter,
  ]
}

public enum WorkspaceNavigationPresentation {
  public static let defaultSection: WorkspaceSection = .writing
  public static let commandMenuItems = WorkspaceVisibilityPolicy.commandMenuPrimarySections.map(
    WorkspaceNavigationItem.init(section:)
  )
  public static let secondaryEntryItems = WorkspaceVisibilityPolicy.secondaryEntrySections.map(WorkspaceNavigationItem.init(section:))
  public static let commandMenuAdvancedItems = (
    WorkspaceVisibilityPolicy.secondaryEntrySections
      + WorkspaceVisibilityPolicy.hiddenNavigationSections
  ).map(WorkspaceNavigationItem.init(section:))

  public static let commandPaletteSections = WorkspaceVisibilityPolicy.commandPaletteSections
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
  public var selectedRange: NSRange?

  public init(
    id: UUID = UUID(),
    draftID: UUID,
    field: String?,
    query: String? = nil,
    selectedRange: NSRange? = nil
  ) {
    self.id = id
    self.draftID = draftID
    self.field = field
    self.query = query
    self.selectedRange = selectedRange
  }
}

public struct ImageInspectorFocusRequest: Identifiable, Equatable, Sendable {
  public var id: UUID
  public var draftID: UUID
  public var attachmentID: UUID

  public init(id: UUID = UUID(), draftID: UUID, attachmentID: UUID) {
    self.id = id
    self.draftID = draftID
    self.attachmentID = attachmentID
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
      return CoreL10n.text("写入仓库")
    case .batchLocalWrite:
      return CoreL10n.text("批量写入")
    case .directCommit:
      return CoreL10n.text("直接提交")
    case .reviewBranch:
      return CoreL10n.text("发布分支")
    case .remoteDirectCommit:
      return CoreL10n.text("线上提交")
    case .remoteReviewRequest:
      return CoreL10n.text("线上 PR/MR")
    case .remotePublishFailure:
      return CoreL10n.text("线上发布失败")
    case .remoteRollback:
      return CoreL10n.text("线上回滚")
    case .remoteReviewWithdrawal:
      return CoreL10n.text("线上 Review 撤回")
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
  public static let maximumRetainedRecords = 250

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

  public static func limitedHistory(_ records: [ReleaseRecord]) -> [ReleaseRecord] {
    Array(records.prefix(maximumRetainedRecords))
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

  public static func resumedRemoteReview(
    original: ReleaseRecord,
    profile: SiteProfile,
    result: RemoteRepositoryPublishResult
  ) -> ReleaseRecord {
    var recovered = original
    recovered.kind = .remoteReviewRequest
    recovered.title = "恢复线上 PR/MR：\(original.siteName ?? profile.name)"
    recovered.summary = "已从部分完成的远端分支继续创建 PR/MR：\(result.branchName) -> \(result.targetBranch)"
    recovered.repositoryProvider = result.provider
    recovered.repositoryBaseURL = profile.repositoryBaseURL
    recovered.repoOwner = profile.repoOwner
    recovered.repoName = profile.repoName
    recovered.branchName = result.branchName
    recovered.targetBranch = result.targetBranch
    recovered.commitSHA = result.commitSHA ?? original.commitSHA
    recovered.reviewURL = result.reviewURL
    recovered.reviewTitle = result.reviewTitle
    return recovered
  }

  public static func remoteRollback(
    original: ReleaseRecord,
    profile: SiteProfile,
    result: RemoteRepositoryRollbackResult,
    createdAt: Date = Date()
  ) -> ReleaseRecord {
    ReleaseRecord(
      kind: .remoteRollback,
      title: CoreL10n.format("线上回滚：%@", original.draftTitle ?? original.title),
      summary: CoreL10n.format("%@ · %@ · 回滚 %@ -> %@", result.provider.displayName, result.targetBranch, String(result.rolledBackCommitSHA.prefix(8)), String(result.rollbackCommitSHA.prefix(8))),
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
      reviewTitle: CoreL10n.format("回滚 %@", original.draftTitle ?? original.title),
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
      title: CoreL10n.format("线上 Review 撤回：%@", original.draftTitle ?? original.title),
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
      reviewTitle: CoreL10n.format("已关闭 %@", original.reviewTitle ?? original.draftTitle ?? original.title),
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
