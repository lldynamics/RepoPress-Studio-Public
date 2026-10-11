import Foundation
import PublishingCoreSupport

public enum RepositoryControlledRebaseError: LocalizedError, Sendable {
  case requiresManualRebase

  public var errorDescription: String? {
    CoreL10n.text("此站点启用了提交签名或受信任 hooks。自动变基暂不支持这些执行权限，请在终端完成变基后重新检查仓库。")
  }
}

extension RepositorySyncProfile {
  func requireAutomaticRebaseAllowed() throws {
    guard !requiresControlledCommitExecution else {
      throw RepositoryControlledRebaseError.requiresManualRebase
    }
  }
}
