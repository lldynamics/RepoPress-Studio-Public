import Foundation

public struct StructuralDraftRepairItem: Identifiable, Sendable {
  public let id: UUID
  public let title: String
  public let repositoryPath: String
}

public struct StructuralFileRepairItem: Identifiable, Sendable {
  public var id: String { repositoryPath }
  public let repositoryPath: String
  public let diff: String
  public let wasMissing: Bool
}

public struct StructuralDraftRepairPreview: Identifiable, Sendable {
  public let id: UUID
  public let profileID: UUID
  public let profileName: String
  public let drafts: [StructuralDraftRepairItem]
  public let files: [StructuralFileRepairItem]
  public let sourceCommit: String?
  public let warnings: [String]
  let profileSnapshot: SiteProfile
  let draftSnapshots: [ArticleDraft]
  let filePreview: LocalPublishPreview?
  var bodyBuffers: [UUID: DraftBodyEditorBuffer] = [:]
}

public struct StructuralDraftRepairResult: Sendable {
  public let backupURL: URL
  public let repairedDraftCount: Int
  public let restoredPaths: [String]
  /// Draft changes have already been persisted if optional file recovery fails.
  public let fileRecoveryError: String?
}

public enum StructuralDraftRepairError: LocalizedError {
  case stalePreview
  case invalidSelection
  case unavailable(String)

  public var errorDescription: String? {
    switch self {
    case .stalePreview:
      return CoreL10n.text("预览后文章、站点配置或文件已变化，未执行修复。请重新扫描并确认。")
    case .invalidSelection:
      return CoreL10n.text("请选择预览中需要修复的记录或文件。")
    case .unavailable(let message): return message
    }
  }
}
