import Foundation

public enum WorkspaceSection: String, CaseIterable, Codable, Identifiable, Sendable {
  case writing
  case library
  case rss
  case sync
  case images
  case contentHealth

  /// Retired wizard routes in saved automation data open the existing site workspace.
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    if value == "siteStarter" {
      self = .sync
    } else if let section = Self(rawValue: value) {
      self = section
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unknown workspace section: \(value)")
    }
  }

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
    case .sync:
      return "globe"
    case .contentHealth:
      return "checklist"
    case .images:
      return "photo.on.rectangle"
    }
  }

  public var keyboardShortcutKey: Character {
    switch self {
    case .writing:
      return "1"
    case .library:
      return "2"
    case .rss:
      return "3"
    case .sync:
      return "4"
    case .images:
      return "6"
    case .contentHealth:
      return "5"
    }
  }

  public var keyboardShortcutLabel: String {
    "⌘\(keyboardShortcutKey)"
  }
}

/// The three durable, user-facing groups in the workspace navigator. The
/// atomic `WorkspaceSection` remains the selected/persisted route; areas only
/// describe how those routes are presented and grouped in navigation.
public enum WorkspaceArea: String, CaseIterable, Identifiable, Sendable {
  case writing
  case resources
  case site

  public var id: String { rawValue }

  public var localizationKey: String {
    "workspace.area.\(rawValue)"
  }

  public var systemImage: String {
    switch self {
    case .writing:
      return "square.and.pencil"
    case .resources:
      return "books.vertical"
    case .site:
      return "globe"
    }
  }

  public var sections: [WorkspaceSection] {
    switch self {
    case .writing:
      return [.writing]
    case .resources:
      return [.library, .rss]
    case .site:
      return [.sync, .contentHealth, .images]
    }
  }

  public var defaultSection: WorkspaceSection {
    switch self {
    case .writing:
      return .writing
    case .resources:
      return .library
    case .site:
      return .sync
    }
  }

  public static func area(for section: WorkspaceSection) -> Self {
    allCases.first(where: { $0.sections.contains(section) }) ?? .writing
  }
}

public enum WorkspaceCenterSurface: String, CaseIterable, Sendable {
  case editor
  case knowledgeLibrary
  case rssReader
  case repository
  case images
  case contentHealth
}

public enum WorkspaceInspectorRoute: String, CaseIterable, Sendable {
  case articleMetadata
  case articleChecks
  case articleImages
  case knowledgeLibrary
  case rssLibrary
  case repository
  case aiAssistant
  case unavailable
}

/// Keeps Inspector routing testable outside SwiftUI. Parent-workspace subpages
/// can suppress the Inspector without introducing placeholder workspace cases.
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
      return .knowledgeLibrary
    case .rss:
      return .rssLibrary
    case .contentHealth:
      return isMaintenancePresented ? .unavailable : .articleChecks
    case .images:
      return .articleImages
    case .sync:
      return isRepositoryHistoryPresented ? .unavailable : .repository
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

extension WorkspaceSection {
  public var centerSurface: WorkspaceCenterSurface {
    switch self {
    case .writing: .editor
    case .library: .knowledgeLibrary
    case .rss: .rssReader
    case .sync: .repository
    case .images: .images
    case .contentHealth: .contentHealth
    }
  }

  public var requiresEditableDraftForCenterSurface: Bool {
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
  /// Primary navigation is an explicit allowlist. New enum cases must never
  /// become user-facing merely because they were added to `WorkspaceSection`.
  public static let commandMenuPrimarySections: [WorkspaceSection] = [
    .writing,
    .library,
    .rss,
    .sync,
    .contentHealth,
    .images,
  ]

  public static let commandPaletteSections = commandMenuPrimarySections
}

public enum WorkspaceNavigationPresentation {
  public static let defaultSection: WorkspaceSection = .writing
  public static let primaryAreas = WorkspaceArea.allCases
  public static let commandMenuItems = WorkspaceVisibilityPolicy.commandMenuPrimarySections.map(
    WorkspaceNavigationItem.init(section:)
  )
  public static let commandPaletteSections = WorkspaceVisibilityPolicy.commandPaletteSections
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
}

public enum ReleaseRecordKind: String, CaseIterable, Codable, Identifiable, Sendable {
  case localWrite
  case batchLocalWrite
  case directCommit
  case reviewBranch
  case remoteDirectCommit
  case remotePreviewBranch
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
    case .remotePreviewBranch:
      return CoreL10n.text("远端预览分支")
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
    case .remotePreviewBranch:
      return "eye.circle"
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
  public var draftSummary: String?
  public var draftCoverAltText: String?
  public var publicPath: String?
  public var publicURLText: String?
  public var sourceDocumentDigest: String?
  public var changedPaths: [String]

  public init(
    draftID: UUID,
    draftTitle: String,
    markdownPath: String,
    draftSummary: String? = nil,
    draftCoverAltText: String? = nil,
    publicPath: String? = nil,
    publicURLText: String? = nil,
    sourceDocumentDigest: String? = nil,
    changedPaths: [String]
  ) {
    self.draftID = draftID
    self.draftTitle = draftTitle
    self.markdownPath = markdownPath
    self.draftSummary = draftSummary
    self.draftCoverAltText = draftCoverAltText
    self.publicPath = publicPath
    self.publicURLText = publicURLText
    self.sourceDocumentDigest = sourceDocumentDigest
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
      draftSummary: planItem.package.draftSummary,
      draftCoverAltText: planItem.package.draftCoverAltText,
      publicPath: planItem.package.publicPath,
      publicURLText: planItem.package.publicURLText,
      sourceDocumentDigest: planItem.package.sourceDocumentDigest,
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
  public var publicPath: String?
  public var publicURLText: String?
  public var sourceDocumentDigest: String?
  public var markdownPath: String?
  public var changedPaths: [String]
  public var repositoryProvider: RepositoryProvider?
  public var repositoryBaseURL: String?
  public var repoOwner: String?
  public var repoName: String?
  public var branchName: String?
  public var targetBranch: String?
  public var commitSHA: String?
  /// A later PR/MR head explicitly accepted by the user. `commitSHA` always
  /// remains the commit produced by the original publish operation.
  public var acceptedReviewHeadCommitSHA: String?
  public var acceptedReviewHeadAt: Date?
  public var reviewNumber: Int?
  public var reviewURL: String?
  public var reviewTitle: String?
  public var reviewStatus: RemoteRepositoryReviewStatusSnapshot?
  public var batchItems: [ReleaseRecordBatchItem]
  public var articlePublishTrackingRequest: ArticlePublishTrackingRequest?
  /// Frozen before the confirmed push; deployment rechecks must not move this boundary.
  public var localWriteResolutionCutoff: Date?
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
    publicPath: String? = nil,
    publicURLText: String? = nil,
    sourceDocumentDigest: String? = nil,
    markdownPath: String? = nil,
    changedPaths: [String] = [],
    repositoryProvider: RepositoryProvider? = nil,
    repositoryBaseURL: String? = nil,
    repoOwner: String? = nil,
    repoName: String? = nil,
    branchName: String? = nil,
    targetBranch: String? = nil,
    commitSHA: String? = nil,
    acceptedReviewHeadCommitSHA: String? = nil,
    acceptedReviewHeadAt: Date? = nil,
    reviewNumber: Int? = nil,
    reviewURL: String? = nil,
    reviewTitle: String? = nil,
    reviewStatus: RemoteRepositoryReviewStatusSnapshot? = nil,
    batchItems: [ReleaseRecordBatchItem] = [],
    articlePublishTrackingRequest: ArticlePublishTrackingRequest? = nil,
    localWriteResolutionCutoff: Date? = nil,
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
    self.publicPath = publicPath
    self.publicURLText = publicURLText
    self.sourceDocumentDigest = sourceDocumentDigest
    self.markdownPath = markdownPath
    self.changedPaths = changedPaths
    self.repositoryProvider = repositoryProvider
    self.repositoryBaseURL = repositoryBaseURL
    self.repoOwner = repoOwner
    self.repoName = repoName
    self.branchName = branchName
    self.targetBranch = targetBranch
    self.commitSHA = commitSHA
    self.acceptedReviewHeadCommitSHA = acceptedReviewHeadCommitSHA
    self.acceptedReviewHeadAt = acceptedReviewHeadAt
    self.reviewNumber = reviewNumber
    self.reviewURL = reviewURL
    self.reviewTitle = reviewTitle
    self.reviewStatus = reviewStatus
    self.batchItems = batchItems
    self.articlePublishTrackingRequest = articlePublishTrackingRequest
    self.localWriteResolutionCutoff = localWriteResolutionCutoff
    self.createdAt = createdAt
  }

  public var shortCommitSHA: String? {
    commitSHA.map { String($0.prefix(8)) }
  }

  /// The target-branch commit that deployment providers must prove. Review
  /// records keep `commitSHA` as the original head commit for auditability;
  /// only a verified merged snapshot can supply the deployment commit.
  public var deploymentCommitSHA: String? {
    if kind == .remoteReviewRequest {
      guard reviewStatus?.state == .merged, reviewHeadIsAccepted else { return nil }
      return reviewStatus?.mergeCommitSHA?.trimmedForPublishing.nilIfEmpty
    }
    return commitSHA?.trimmedForPublishing.nilIfEmpty
  }

  public var hasUnconfirmedReviewHeadDrift: Bool {
    guard kind == .remoteReviewRequest,
      let observed = reviewStatus?.headCommitSHA?.trimmedForPublishing.nilIfEmpty,
      let original = commitSHA?.trimmedForPublishing.nilIfEmpty
    else { return false }
    return observed.caseInsensitiveCompare(original) != .orderedSame
      && observed.caseInsensitiveCompare(acceptedReviewHeadCommitSHA?.trimmedForPublishing ?? "")
        != .orderedSame
  }

  var reviewHeadIsAccepted: Bool {
    !hasUnconfirmedReviewHeadDrift
  }

  var deploymentBranchName: String? {
    if kind == .remoteReviewRequest, reviewStatus?.state == .merged {
      return reviewStatus?.targetBranch.trimmedForPublishing.nilIfEmpty
    }
    return branchName?.trimmedForPublishing.nilIfEmpty
  }

  public static func limitedHistory(_ records: [ReleaseRecord]) -> [ReleaseRecord] {
    Array(records.prefix(maximumRetainedRecords))
  }

  public var reviewWebURL: URL? {
    reviewURL.flatMap(URL.init(string:))
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
    case publicPath
    case publicURLText
    case sourceDocumentDigest
    case markdownPath
    case changedPaths
    case repositoryProvider
    case repositoryBaseURL
    case repoOwner
    case repoName
    case branchName
    case targetBranch
    case commitSHA
    case acceptedReviewHeadCommitSHA
    case acceptedReviewHeadAt
    case reviewNumber
    case reviewURL
    case reviewTitle
    case reviewStatus
    case batchItems
    case articlePublishTrackingRequest
    case localWriteResolutionCutoff
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
    publicPath = try container.decodeIfPresent(String.self, forKey: .publicPath)
    publicURLText = try container.decodeIfPresent(String.self, forKey: .publicURLText)
    sourceDocumentDigest = try container.decodeIfPresent(String.self, forKey: .sourceDocumentDigest)
    markdownPath = try container.decodeIfPresent(String.self, forKey: .markdownPath)
    changedPaths = try container.decodeIfPresent([String].self, forKey: .changedPaths) ?? []
    repositoryProvider = try container.decodeIfPresent(
      RepositoryProvider.self, forKey: .repositoryProvider)
    repositoryBaseURL = try container.decodeIfPresent(String.self, forKey: .repositoryBaseURL)
    repoOwner = try container.decodeIfPresent(String.self, forKey: .repoOwner)
    repoName = try container.decodeIfPresent(String.self, forKey: .repoName)
    branchName = try container.decodeIfPresent(String.self, forKey: .branchName)
    targetBranch = try container.decodeIfPresent(String.self, forKey: .targetBranch)
    commitSHA = try container.decodeIfPresent(String.self, forKey: .commitSHA)
    acceptedReviewHeadCommitSHA = try container.decodeIfPresent(
      String.self, forKey: .acceptedReviewHeadCommitSHA)
    acceptedReviewHeadAt = try container.decodeIfPresent(Date.self, forKey: .acceptedReviewHeadAt)
    reviewNumber = try container.decodeIfPresent(Int.self, forKey: .reviewNumber)
    reviewURL = try container.decodeIfPresent(String.self, forKey: .reviewURL)
    reviewTitle = try container.decodeIfPresent(String.self, forKey: .reviewTitle)
    reviewStatus = try container.decodeIfPresent(
      RemoteRepositoryReviewStatusSnapshot.self,
      forKey: .reviewStatus
    )
    batchItems =
      try container.decodeIfPresent([ReleaseRecordBatchItem].self, forKey: .batchItems) ?? []
    articlePublishTrackingRequest = try container.decodeIfPresent(
      ArticlePublishTrackingRequest.self, forKey: .articlePublishTrackingRequest)
    localWriteResolutionCutoff = try container.decodeIfPresent(
      Date.self, forKey: .localWriteResolutionCutoff)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
  }
}
