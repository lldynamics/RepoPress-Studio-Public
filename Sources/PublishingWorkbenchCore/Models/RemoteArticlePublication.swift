import Foundation

/// Immutable, remote-backed review evidence for one article publication.
/// It deliberately contains only the package files, never a repository scan
/// or an arbitrary working-tree diff.
public struct RemoteArticlePublicationReview: Hashable, Sendable, Identifiable {
  public struct File: Hashable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var kind: PublishFileKind
    public var operation: PublishFileOperation
    public var status: PublishFileDiffStatus
    public var byteSize: Int64
    /// SHA-256 of the exact upsert payload. This catches media replacements
    /// that preserve an attachment URL, source path and byte count.
    public var contentSHA256: String?
    public var remoteVersion: String?
    public var lineDiff: String?

    public init(
      path: String,
      kind: PublishFileKind,
      operation: PublishFileOperation,
      status: PublishFileDiffStatus,
      byteSize: Int64,
      contentSHA256: String? = nil,
      remoteVersion: String? = nil,
      lineDiff: String? = nil
    ) {
      self.path = path
      self.kind = kind
      self.operation = operation
      self.status = status
      self.byteSize = byteSize
      self.contentSHA256 = contentSHA256
      self.remoteVersion = remoteVersion
      self.lineDiff = lineDiff
    }
  }

  public var id: UUID
  public var package: PublishPackage
  public var target: RemoteRepositoryPublishTargetSnapshot
  public var targetBranchVersion: String
  public var files: [File]
  public var reviewedAt: Date

  public init(
    id: UUID = UUID(),
    package: PublishPackage,
    target: RemoteRepositoryPublishTargetSnapshot,
    targetBranchVersion: String,
    files: [File],
    reviewedAt: Date = Date()
  ) {
    self.id = id
    self.package = package
    self.target = target
    self.targetBranchVersion = targetBranchVersion
    self.files = files
    self.reviewedAt = reviewedAt
  }

  public var changedPaths: [String] {
    files.filter { $0.status != .unchanged }.map(\.path)
  }

  public var isFullySynchronized: Bool {
    !files.isEmpty && files.allSatisfy { $0.status == .unchanged }
  }
}

public enum RemoteArticlePublicationReviewError: LocalizedError, Equatable {
  case confirmationExpired
  case remoteChanged

  public var errorDescription: String? {
    switch self {
    case .confirmationExpired:
      return CoreL10n.text("待发布正文、站点或目标已变化，请重新打开确认页审阅远端清单。")
    case .remoteChanged:
      return CoreL10n.text("目标分支或远端文件已在确认后变化，请重新审阅，未写入远端。")
    }
  }
}
