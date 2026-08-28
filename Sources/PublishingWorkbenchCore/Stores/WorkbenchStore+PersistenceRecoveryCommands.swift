import Foundation

public enum PersistenceRecoveryResetResult: Equatable {
  case reset(archiveURL: URL)
  case failed(archiveURL: URL?, message: String)
}

extension WorkbenchStore {
  @discardableResult
  public func exportPersistenceRecoveryFiles(to directoryURL: URL) -> URL? {
    guard isPersistenceRecoveryWriteProtected else { return nil }
    do {
      return try persistenceStore.exportRecoveryFiles(to: directoryURL)
    } catch {
      persistenceStore.recordRecoveryFailure(error)
      return nil
    }
  }

  /// Installs a validated recovery snapshot on disk. The caller must restart the
  /// app before using it so the temporary blank in-memory store is never merged
  /// into the recovered snapshot.
  @discardableResult
  public func installPersistenceRecoverySnapshot(from sourceURL: URL) -> Bool {
    guard isPersistenceRecoveryWriteProtected else { return false }
    do {
      _ = try persistenceStore.installRecoverySnapshot(from: sourceURL)
      return true
    } catch {
      persistenceStore.recordRecoveryFailure(error)
      return false
    }
  }

  /// Archives the unreadable primary and backup files, then explicitly permits
  /// the temporary blank workbench to become the new saved state.
  public func resetPersistenceAfterUnrecoverableSnapshotResult() -> PersistenceRecoveryResetResult {
    guard isPersistenceRecoveryWriteProtected else {
      return .failed(
        archiveURL: nil,
        message: CoreL10n.text("当前工作台不处于恢复保护状态，未执行重置。")
      )
    }
    do {
      let archiveURL = try persistenceStore.resetAfterUnrecoverableSnapshot()
      // The reset completion must not be reported until the replacement
      // snapshot has actually been committed. `save()` is intentionally
      // asynchronous for ordinary editing, but recovery feedback must surface
      // a failed blank-workbench write immediately.
      persistenceStore.persistence.save(store: self)
      if persistenceStore.hasUnsavedChanges {
        return .failed(
          archiveURL: archiveURL,
          message: persistenceStore.lastSaveError
            ?? CoreL10n.text("空白工作台未能保存，请检查存储位置后重试。")
        )
      }
      return .reset(archiveURL: archiveURL)
    } catch {
      persistenceStore.recordRecoveryFailure(error)
      return .failed(archiveURL: nil, message: error.localizedDescription)
    }
  }

  @discardableResult
  public func resetPersistenceAfterUnrecoverableSnapshot() -> URL? {
    switch resetPersistenceAfterUnrecoverableSnapshotResult() {
    case .reset(let archiveURL):
      return archiveURL
    case .failed:
      return nil
    }
  }
}
