import Foundation

/// A read-only review of the exact remote version. No local worktree is merged.
public struct PreviewPromotionFile: Identifiable, Hashable, Sendable {
  public var id: String { path }
  public let path: String
  public let status: String
  public let blobSHA: String
  public let additions: Int
  public let deletions: Int
  public let patch: String?
}

public struct PreviewPromotionPlan: Identifiable, Hashable, Sendable {
  public var id: UUID { record.id }
  public let record: ReleaseRecord
  public let profile: SiteProfile
  public let sourceCommitSHA: String
  public let targetCommitSHA: String
  public let files: [PreviewPromotionFile]
  public let markdown: String
  public let checkedAt: Date
}

public struct ReviewMergePlan: Identifiable, Hashable, Sendable {
  public var id: UUID { record.id }
  public let record: ReleaseRecord
  public let profile: SiteProfile
  public let sourceCommitSHA: String
  public let targetCommitSHA: String
  public let files: [PreviewPromotionFile]
  public let markdown: String
  public let blockers: [String]
  public let mergedCommitSHA: String?
  public let checkedAt: Date
  public var canMerge: Bool { blockers.isEmpty && mergedCommitSHA == nil && !files.isEmpty }
}

/// Read permissions required by the two independent GitHub merge-check APIs.
public enum GitHubReviewCheckPermission: String, Equatable, Sendable {
  case checks
  case commitStatuses

  public var requiredPermission: String {
    switch self {
    case .checks: return "Checks: Read-only"
    case .commitStatuses: return "Commit statuses: Read-only"
    }
  }

  var operationDescription: String {
    switch self {
    case .checks: return CoreL10n.text("构建检查（Check runs）")
    case .commitStatuses: return CoreL10n.text("提交状态（Commit statuses）")
    }
  }
}

public enum PreviewPromotionError: LocalizedError, Equatable {
  case unavailable(String)
  case changed
  case busy
  case persistence

  public var errorDescription: String? {
    switch self {
    case .unavailable(let reason): return reason
    case .changed:
      return CoreL10n.text("文章、站点或远端版本已变化，请刷新后重新审阅。")
    case .busy:
      return CoreL10n.text("已有远端操作正在运行，请稍后继续。")
    case .persistence:
      return CoreL10n.text("未能保存发布进度，已停止后续写入；请重新检查远端状态后继续。")
    }
  }
}
