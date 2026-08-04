import Foundation

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
  @discardableResult
  public func resetPersistenceAfterUnrecoverableSnapshot() -> URL? {
    guard isPersistenceRecoveryWriteProtected else { return nil }
    do {
      let archiveURL = try persistenceStore.resetAfterUnrecoverableSnapshot()
      save()
      return archiveURL
    } catch {
      persistenceStore.recordRecoveryFailure(error)
      return nil
    }
  }
}
