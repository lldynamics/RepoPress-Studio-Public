import Combine
import Foundation

/// Owns persistence lifecycle state and I/O. The root store supplies a frozen
/// cross-domain snapshot, keeping persistence from reaching into feature state.
@MainActor
final class WorkbenchPersistenceStore: ObservableObject {
  let persistence: WorkbenchPersistence
  @Published private(set) var hasUnsavedChanges = false
  @Published private(set) var lastSaveError: String?
  @Published private(set) var recoveryMessage: String?
  @Published var status = "尚未保存"

  private var autosaveTask: Task<Void, Never>?
  private var backgroundSaveTask: Task<Void, Never>?
  private var revision: UInt64 = 0

  init(persistence: WorkbenchPersistence) {
    self.persistence = persistence
  }

  func loadWithRecovery() throws -> WorkbenchSnapshotLoadResult {
    try persistence.loadWithRecovery()
  }

  func setRecoveryMessage(_ message: String?) {
    recoveryMessage = message
  }

  func markStatus(_ value: String) {
    status = value
    if value == "有未保存修改" {
      hasUnsavedChanges = true
    }
  }

  func saveImmediately(snapshot: WorkbenchSnapshot) {
    autosaveTask?.cancel()
    autosaveTask = nil
    revision &+= 1
    persist(snapshot)
  }

  func flush(snapshot: WorkbenchSnapshot) -> Bool {
    autosaveTask?.cancel()
    autosaveTask = nil
    revision &+= 1
    guard hasUnsavedChanges else { return true }
    status = "正在保存…"
    persist(snapshot)
    return !hasUnsavedChanges
  }

  func scheduleAutosave(snapshot: @escaping @MainActor () -> WorkbenchSnapshot?) {
    autosaveTask?.cancel()
    hasUnsavedChanges = true
    status = "有未保存修改"
    autosaveTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 750_000_000)
      } catch {
        return
      }
      guard !Task.isCancelled, let self else { return }
      self.autosaveTask = nil
      guard let snapshot = snapshot() else { return }
      self.saveInBackground(snapshot: snapshot)
    }
  }

  func recordFailure(_ error: Error) {
    hasUnsavedChanges = true
    lastSaveError = error.localizedDescription
    status = "保存失败：\(error.localizedDescription)"
  }

  func recordSuccess(backupWarning: String? = nil) {
    hasUnsavedChanges = false
    lastSaveError = backupWarning
    status = backupWarning == nil ? "已保存" : "已保存（备份失败）"
  }

  private func saveInBackground(snapshot: WorkbenchSnapshot) {
    guard hasUnsavedChanges else { return }
    revision &+= 1
    let expectedRevision = revision
    let persistence = persistence
    status = "正在后台保存…"
    backgroundSaveTask = Task.detached { [weak self, persistence, snapshot, expectedRevision] in
      let prepared: Result<WorkbenchPreparedPersistenceSave, Error> = Result {
        try persistence.prepareSave(snapshot, reclaimUnreferencedAttachments: false)
      }
      guard !Task.isCancelled else { return }
      await self?.commitBackgroundSave(prepared, expectedRevision: expectedRevision)
    }
  }

  private func commitBackgroundSave(
    _ prepared: Result<WorkbenchPreparedPersistenceSave, Error>,
    expectedRevision: UInt64
  ) {
    guard expectedRevision == revision else { return }
    backgroundSaveTask = nil
    do {
      finish(try persistence.commit(prepared.get()))
    } catch {
      recordFailure(error)
    }
  }

  private func persist(_ snapshot: WorkbenchSnapshot) {
    do {
      finish(try persistence.save(snapshot))
    } catch {
      recordFailure(error)
    }
  }

  private func finish(_ result: WorkbenchPersistenceSaveResult) {
    hasUnsavedChanges = false
    switch result {
    case .saved:
      lastSaveError = nil
      status = "已保存"
    case .savedWithoutBackup(let message):
      lastSaveError = message
      status = "已保存（备份失败）"
    }
  }
}
