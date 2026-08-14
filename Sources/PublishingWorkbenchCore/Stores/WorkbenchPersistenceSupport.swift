
import Foundation
public enum WorkbenchInitialSnapshotSource: Sendable {
  case persistence
  case preloaded(WorkbenchSnapshotLoadResult)
  case loadFailure(String)
}

public enum WorkbenchPersistenceSaveResult: Sendable, Equatable {
  case saved
  case savedWithoutBackup(String)
}

/// A fully encoded snapshot that is ready for the short, atomic disk commit.
/// Construct and commit this off the main actor. The persistence store checks
/// revisions before and after its serialized commit so newer editor state is
/// never marked as saved by an older snapshot.
public struct WorkbenchPreparedPersistenceSave: Sendable {
  let data: Data
  let retiredFeatureArchives: [WorkbenchRetiredFeatureArchive]
}

struct WorkbenchRetiredFeatureArchive: Sendable {
  var fileName: String
  var data: Data
}

public enum WorkbenchPersistenceError: LocalizedError, Sendable {
  case unrecoverableSnapshot(primary: String, backup: String?)
  case retiredFeatureArchiveConflict(String)
  case recoveryFilesUnavailable
  case invalidRecoverySnapshot(String)
  case recoveryArchiveCleanupFailed(path: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case .unrecoverableSnapshot:
      return "工作台数据无法读取，原始文件未被覆盖。"
    case .retiredFeatureArchiveConflict(let fileName):
      return "退役功能数据归档冲突：\(fileName)。原始文件未被覆盖。"
    case .recoveryFilesUnavailable:
      return "没有可归档或导出的工作台故障文件。"
    case .invalidRecoverySnapshot(let message):
      return "所选恢复文件不是有效的工作台快照：\(message)"
    case .recoveryArchiveCleanupFailed(let path, let reason):
      return "归档工作台故障文件失败：\(reason)。临时归档目录保留在 \(path)。"
    }
  }
}
