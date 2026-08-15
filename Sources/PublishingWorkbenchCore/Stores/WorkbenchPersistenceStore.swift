import Combine
import Foundation

private final class WorkbenchPersistenceRevisionState: @unchecked Sendable {
  private let lock = NSLock()
  private var revision: UInt64 = 0

  @discardableResult
  func advance() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    revision &+= 1
    return revision
  }

  func current() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return revision
  }

  func isCurrent(_ expectedRevision: UInt64) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return revision == expectedRevision
  }
}

private struct WorkbenchBackgroundSaveError: LocalizedError, Sendable {
  let message: String

  var errorDescription: String? { message }
}

private enum WorkbenchBackgroundCommitOutcome: Sendable {
  case superseded
  case attempted(
    Result<WorkbenchPersistenceSaveResult, WorkbenchBackgroundSaveError>,
    revisionWasCurrentAfterAttempt: Bool
  )
}

/// Serializes every disk commit, including the synchronous exit flush. A
/// cancelled task cannot interrupt an atomic write, so ordering is enforced by
/// this queue and revision checks instead of task-cancellation assumptions.
private final class WorkbenchPersistenceCommitCoordinator: @unchecked Sendable {
  typealias CommitBackgroundSave =
    @Sendable (
      WorkbenchPersistence,
      WorkbenchPreparedPersistenceSave
    ) throws -> WorkbenchPersistenceSaveResult

  private let queue = DispatchQueue(
    label: "PersonalSitePublisherMac.WorkbenchPersistenceCommit",
    qos: .utility
  )
  private let commitBackgroundSave: CommitBackgroundSave

  init(commitBackgroundSave: @escaping CommitBackgroundSave) {
    self.commitBackgroundSave = commitBackgroundSave
  }

  func commit(
    _ preparedSave: WorkbenchPreparedPersistenceSave,
    persistence: WorkbenchPersistence,
    expectedRevision: UInt64,
    revisionState: WorkbenchPersistenceRevisionState
  ) -> WorkbenchBackgroundCommitOutcome {
    queue.sync {
      guard revisionState.isCurrent(expectedRevision) else {
        return .superseded
      }

      let result: Result<WorkbenchPersistenceSaveResult, WorkbenchBackgroundSaveError>
      do {
        result = .success(try commitBackgroundSave(persistence, preparedSave))
      } catch {
        result = .failure(WorkbenchBackgroundSaveError(message: error.localizedDescription))
      }
      return .attempted(
        result,
        revisionWasCurrentAfterAttempt: revisionState.isCurrent(expectedRevision)
      )
    }
  }

  func saveSynchronously(
    _ snapshot: WorkbenchSnapshot,
    persistence: WorkbenchPersistence
  ) throws -> WorkbenchPersistenceSaveResult {
    try queue.sync {
      try persistence.save(snapshot)
    }
  }

  func saveSynchronously(
    _ input: WorkbenchPersistenceSnapshotInput,
    persistence: WorkbenchPersistence
  ) throws -> WorkbenchPersistenceSaveResult {
    try queue.sync {
      try persistence.save(persistence.snapshot(from: input))
    }
  }
}

/// Owns persistence lifecycle state and I/O. The root store supplies a frozen
/// cross-domain snapshot, keeping persistence from reaching into feature state.
@MainActor
final class WorkbenchPersistenceStore: ObservableObject {
  typealias PrepareBackgroundSave =
    @Sendable (
      WorkbenchPersistence,
      WorkbenchSnapshot
    ) throws -> WorkbenchPreparedPersistenceSave
  typealias CommitBackgroundSave =
    @Sendable (
      WorkbenchPersistence,
      WorkbenchPreparedPersistenceSave
    ) throws -> WorkbenchPersistenceSaveResult

  let persistence: WorkbenchPersistence
  @Published private(set) var hasUnsavedChanges = false
  @Published private(set) var lastSaveError: String?
  @Published private(set) var recoveryMessage: String?
  @Published private(set) var isRecoveryWriteProtected = false
  @Published var status = "尚未保存"

  private var autosaveTask: Task<Void, Never>?
  private var backgroundSaveTask: Task<Void, Never>?
  private let revisionState = WorkbenchPersistenceRevisionState()
  private let prepareBackgroundSave: PrepareBackgroundSave
  private let commitCoordinator: WorkbenchPersistenceCommitCoordinator

  init(
    persistence: WorkbenchPersistence,
    prepareBackgroundSave: @escaping PrepareBackgroundSave = { persistence, snapshot in
      try persistence.prepareSave(snapshot, reclaimUnreferencedAttachments: false)
    },
    commitBackgroundSave: @escaping CommitBackgroundSave = { persistence, preparedSave in
      try persistence.commit(preparedSave)
    }
  ) {
    self.persistence = persistence
    self.prepareBackgroundSave = prepareBackgroundSave
    self.commitCoordinator = WorkbenchPersistenceCommitCoordinator(
      commitBackgroundSave: commitBackgroundSave
    )
  }

  func loadWithRecovery() throws -> WorkbenchSnapshotLoadResult {
    try persistence.loadWithRecovery()
  }

  func setRecoveryMessage(_ message: String?) {
    recoveryMessage = message
  }

  func protectWritesForUnrecoverableSnapshot(message: String) {
    autosaveTask?.cancel()
    autosaveTask = nil
    revisionState.advance()
    isRecoveryWriteProtected = true
    recoveryMessage = message
    lastSaveError = "必须先恢复备份或明确重置，当前工作台不会覆盖原始数据。"
    status = "恢复保护中：原始数据尚未被覆盖"
  }

  @discardableResult
  func resetAfterUnrecoverableSnapshot() throws -> URL {
    let archiveURL = try persistence.archiveUnrecoverableSnapshotFiles()
    revisionState.advance()
    isRecoveryWriteProtected = false
    recoveryMessage = nil
    lastSaveError = nil
    status = "已归档故障数据，正在保存空白工作台…"
    return archiveURL
  }

  @discardableResult
  func exportRecoveryFiles(to directoryURL: URL) throws -> URL {
    let exportURL = try persistence.exportRecoveryFiles(to: directoryURL)
    status = "恢复保护中：故障文件已导出"
    return exportURL
  }

  @discardableResult
  func installRecoverySnapshot(from sourceURL: URL) throws -> URL {
    let archiveURL = try persistence.installRecoverySnapshot(from: sourceURL)
    revisionState.advance()
    recoveryMessage = "恢复文件已安装。应用将重新启动并载入该快照。"
    lastSaveError = nil
    status = "恢复文件已安装，等待重新启动"
    return archiveURL
  }

  func markStatus(_ value: String) {
    if value == "有未保存修改" {
      markUnsavedChanges()
      return
    }
    if status != value {
      status = value
    }
  }

  func markUnsavedChanges() {
    revisionState.advance()
    if !hasUnsavedChanges {
      hasUnsavedChanges = true
    }
    if isRecoveryWriteProtected {
      status = "恢复保护中：原始数据尚未被覆盖"
    } else if status != "有未保存修改" {
      status = "有未保存修改"
    }
  }

  func saveImmediately(snapshot: WorkbenchSnapshot) {
    autosaveTask?.cancel()
    autosaveTask = nil
    markUnsavedChanges()
    guard !isRecoveryWriteProtected else { return }
    saveInBackground(snapshot: snapshot)
  }

  func saveImmediately(input: WorkbenchPersistenceSnapshotInput) {
    autosaveTask?.cancel()
    autosaveTask = nil
    markUnsavedChanges()
    guard !isRecoveryWriteProtected else { return }
    saveInBackground(input: input)
  }

  func flush(snapshot: WorkbenchSnapshot) -> Bool {
    autosaveTask?.cancel()
    autosaveTask = nil
    revisionState.advance()
    if isRecoveryWriteProtected {
      status = "恢复保护中：原始数据尚未被覆盖"
      return true
    }
    guard hasUnsavedChanges else { return true }
    status = "正在保存…"
    persist(snapshot)
    return !hasUnsavedChanges
  }

  func flush(input: WorkbenchPersistenceSnapshotInput) -> Bool {
    autosaveTask?.cancel()
    autosaveTask = nil
    revisionState.advance()
    if isRecoveryWriteProtected {
      status = "恢复保护中：原始数据尚未被覆盖"
      return true
    }
    guard hasUnsavedChanges else { return true }
    status = "正在保存…"
    persist(input)
    return !hasUnsavedChanges
  }

  func scheduleAutosave(snapshot: @escaping @MainActor () -> WorkbenchSnapshot?) {
    autosaveTask?.cancel()
    markUnsavedChanges()
    guard !isRecoveryWriteProtected else { return }
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

  func scheduleAutosave(input: @escaping @MainActor () -> WorkbenchPersistenceSnapshotInput?) {
    autosaveTask?.cancel()
    markUnsavedChanges()
    guard !isRecoveryWriteProtected else { return }
    autosaveTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 750_000_000)
      } catch {
        return
      }
      guard !Task.isCancelled, let self else { return }
      self.autosaveTask = nil
      guard let input = input() else { return }
      self.saveInBackground(input: input)
    }
  }

  func recordFailure(_ error: Error) {
    hasUnsavedChanges = true
    lastSaveError = error.localizedDescription
    status = "保存失败：\(error.localizedDescription)"
  }

  func recordRecoveryFailure(_ error: Error) {
    lastSaveError = error.localizedDescription
    recoveryMessage = "恢复操作失败：\(error.localizedDescription)"
    status = "恢复保护中：请重新选择恢复操作"
  }

  func recordSuccess(backupWarning: String? = nil) {
    hasUnsavedChanges = false
    lastSaveError = backupWarning
    status = backupWarning == nil ? "已保存" : "已保存（备份失败）"
  }

  func waitForCurrentBackgroundSave() async {
    let task = backgroundSaveTask
    await task?.value
  }

  func waitForPendingSave() async {
    let pendingAutosave = autosaveTask
    await pendingAutosave?.value
    await waitForCurrentBackgroundSave()
  }

  private func saveInBackground(snapshot: WorkbenchSnapshot) {
    guard hasUnsavedChanges, !isRecoveryWriteProtected else { return }
    let expectedRevision = revisionState.current()
    let persistence = persistence
    let prepareBackgroundSave = prepareBackgroundSave
    let commitCoordinator = commitCoordinator
    let revisionState = revisionState
    status = "正在后台保存…"
    backgroundSaveTask = Task.detached {
      [
        weak self,
        persistence,
        snapshot,
        expectedRevision,
        prepareBackgroundSave,
        commitCoordinator,
        revisionState,
      ] in
      let outcome: WorkbenchBackgroundCommitOutcome
      do {
        let prepared = try prepareBackgroundSave(persistence, snapshot)
        outcome = commitCoordinator.commit(
          prepared,
          persistence: persistence,
          expectedRevision: expectedRevision,
          revisionState: revisionState
        )
      } catch {
        outcome = .attempted(
          .failure(WorkbenchBackgroundSaveError(message: error.localizedDescription)),
          revisionWasCurrentAfterAttempt: revisionState.isCurrent(expectedRevision)
        )
      }
      await self?.finishBackgroundSave(outcome, expectedRevision: expectedRevision)
    }
  }

  private func saveInBackground(input: WorkbenchPersistenceSnapshotInput) {
    guard hasUnsavedChanges, !isRecoveryWriteProtected else { return }
    let expectedRevision = revisionState.current()
    let persistence = persistence
    let prepareBackgroundSave = prepareBackgroundSave
    let commitCoordinator = commitCoordinator
    let revisionState = revisionState
    status = "正在后台保存…"
    backgroundSaveTask = Task.detached {
      [
        weak self,
        persistence,
        input,
        expectedRevision,
        prepareBackgroundSave,
        commitCoordinator,
        revisionState,
      ] in
      let outcome: WorkbenchBackgroundCommitOutcome
      do {
        // The frozen input contains no store reference. Normalization and
        // encoding therefore stay on this detached persistence worker.
        let snapshot = persistence.snapshot(from: input)
        let prepared = try prepareBackgroundSave(persistence, snapshot)
        outcome = commitCoordinator.commit(
          prepared,
          persistence: persistence,
          expectedRevision: expectedRevision,
          revisionState: revisionState
        )
      } catch {
        outcome = .attempted(
          .failure(WorkbenchBackgroundSaveError(message: error.localizedDescription)),
          revisionWasCurrentAfterAttempt: revisionState.isCurrent(expectedRevision)
        )
      }
      await self?.finishBackgroundSave(outcome, expectedRevision: expectedRevision)
    }
  }

  private func finishBackgroundSave(
    _ outcome: WorkbenchBackgroundCommitOutcome,
    expectedRevision: UInt64
  ) {
    guard revisionState.isCurrent(expectedRevision) else { return }
    guard case .attempted(let result, let revisionWasCurrentAfterAttempt) = outcome,
      revisionWasCurrentAfterAttempt
    else {
      return
    }
    backgroundSaveTask = nil
    do {
      finish(try result.get())
    } catch {
      recordFailure(error)
    }
  }

  private func persist(_ snapshot: WorkbenchSnapshot) {
    do {
      finish(
        try commitCoordinator.saveSynchronously(
          snapshot,
          persistence: persistence
        )
      )
    } catch {
      recordFailure(error)
    }
  }

  private func persist(_ input: WorkbenchPersistenceSnapshotInput) {
    do {
      finish(
        try commitCoordinator.saveSynchronously(
          input,
          persistence: persistence
        )
      )
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
