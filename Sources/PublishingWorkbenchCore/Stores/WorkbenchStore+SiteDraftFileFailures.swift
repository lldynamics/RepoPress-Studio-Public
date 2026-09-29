import Foundation

public enum SiteDraftFileSaveState: Equatable, Sendable {
  case pending(repositoryPath: String)
  case saved(repositoryPath: String, savedAt: Date)
  case failed(repositoryPath: String, message: String)

  public var repositoryPath: String {
    switch self {
    case .pending(let repositoryPath),
      .saved(let repositoryPath, _),
      .failed(let repositoryPath, _):
      return repositoryPath
    }
  }
}

extension WorkbenchStore {
  /// Only failures that blocked the latest flush belong in the exit error.
  /// Full file paths remain available in each group's details.
  var siteDraftFileFlushErrorMessage: String? {
    let failures = currentSiteDraftFileSaveFailures.filter {
      siteDraftFileFlushFailureIDs.contains($0.draftID)
    }
    let groups = SiteDraftFileSaveFailureGroup.grouped(failures)
    guard !groups.isEmpty else { return nil }
    return groups.map(\.summary).joined(separator: "\n\n")
  }

  func setSiteDraftFileFailureMessage(
    _ error: Error, draftID: UUID, profile: SiteProfile
  ) {
    if let state = siteDraftFileSaveStates[draftID] {
      siteDraftFileSaveFailures[draftID] = SiteDraftFileSaveFailure(
        draftID: draftID, profile: profile, repositoryPath: state.repositoryPath, error: error
      )
    }
    scheduleAutosave()
    if case LocalPublishPreviewError.missingRepositoryRoot = error {
      siteDraftFileFlushFailureIDs.remove(draftID)
      siteDraftFileSaveFailures[draftID] = nil
      setPublishActionMessage(
        CoreL10n.text("当前站点未选择本地项目；站点草稿仍保存在软件中，请选择项目后使用“加入项目”重试。"),
        status: .warning
      )
    } else {
      setPublishActionMessage(
        CoreL10n.format("站点草稿写入项目失败：%@", error.localizedDescription),
        status: .failure
      )
    }
  }
}
