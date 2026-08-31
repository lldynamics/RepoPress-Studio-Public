import Combine
import Foundation

private struct WorkbenchOperationLedgerIOState: Sendable {
  var document: WorkbenchOperationLedgerDocument
  var recoveryMessage: String?
  var loadErrorMessage: String?
  var writeErrorMessage: String?
}

private enum WorkbenchOperationLedgerMutation: Sendable {
  case append(WorkbenchOperationEventRecord)
  case setRetentionPolicy(WorkbenchOperationLogRetentionPolicy)
  case clear(Date)

  func applying(to document: WorkbenchOperationLedgerDocument) -> WorkbenchOperationLedgerDocument {
    var candidate = document
    switch self {
    case .append(let record):
      candidate.records.append(record)
    case .setRetentionPolicy(let policy):
      candidate.retentionPolicy = policy
    case .clear(let date):
      candidate.visibleSince = date
      candidate.records = []
    }
    return candidate
  }
}

@MainActor
public final class WorkbenchOperationHistoryStore: ObservableObject {
  private let persistence: WorkbenchOperationLedgerPersistence
  private let now: @Sendable () -> Date
  private var persistenceTail: Task<WorkbenchOperationLedgerIOState, Never>
  private var revision: UInt64 = 0

  @Published public private(set) var document: WorkbenchOperationLedgerDocument
  @Published public private(set) var lastErrorMessage: String?
  @Published public private(set) var recoveryMessage: String?

  public init(
    persistence: WorkbenchOperationLedgerPersistence,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.persistence = persistence
    self.now = now
    self.document = WorkbenchOperationLedgerDocument()
    self.recoveryMessage = nil
    self.lastErrorMessage = nil

    // The full load/recovery/quarantine path performs filesystem I/O, so it
    // must never execute while the observable store holds the main actor.
    let initialLoad = Self.makeInitialLoadTask(persistence: persistence, now: now)
    self.persistenceTail = initialLoad
    Task { [weak self] in
      let state = await initialLoad.value
      self?.applyInitialLoad(state)
    }
  }

  public var records: [WorkbenchOperationEventRecord] { document.records }

  public var retentionPolicy: WorkbenchOperationLogRetentionPolicy {
    document.retentionPolicy
  }

  public var visibleSince: Date? { document.visibleSince }

  /// Applies the record to the UI projection and queues persistence. A true
  /// result is not a disk-durability acknowledgement; await `flush()` when
  /// the caller needs a durable ledger snapshot.
  @discardableResult
  public func record(_ record: WorkbenchOperationEventRecord) -> Bool {
    enqueue(.append(record))
  }

  /// Queues a retention update after applying it to the UI projection. Use
  /// `flush()` before treating the update as durable.
  @discardableResult
  public func setRetentionPolicy(_ policy: WorkbenchOperationLogRetentionPolicy) -> Bool {
    guard policy != document.retentionPolicy else { return true }
    return enqueue(.setRetentionPolicy(policy))
  }

  /// Clears the unified activity projection without deleting canonical release,
  /// maintenance, automation, AI, or deployment records.
  /// Queues a clear watermark after applying it to the UI projection. Use
  /// `flush()` before treating the update as durable.
  @discardableResult
  public func clearHistory(at date: Date? = nil) -> Bool {
    enqueue(.clear(date ?? now()))
  }

  public func visibleCutoff(relativeTo date: Date? = nil) -> Date? {
    let retentionCutoff = retentionPolicy.cutoffDate(relativeTo: date ?? now())
    switch (visibleSince, retentionCutoff) {
    case (.none, .none):
      return nil
    case (.some(let visibleSince), .none):
      return visibleSince
    case (.none, .some(let retentionCutoff)):
      return retentionCutoff
    case (.some(let visibleSince), .some(let retentionCutoff)):
      return max(visibleSince, retentionCutoff)
    }
  }

  public func dismissMessages() {
    lastErrorMessage = nil
    recoveryMessage = nil
  }

  /// Waits for every mutation accepted before this call and returns the exact
  /// ledger snapshot that is safe to freeze into a workspace backup. A nil
  /// result means the latest queued write failed; the user-facing error is
  /// published on this main-actor store.
  public func flush() async -> WorkbenchOperationLedgerDocument? {
    let pending = persistenceTail
    let revisionAtFlush = revision
    let state = await pending.value
    if revision == revisionAtFlush {
      document = state.document
      applyMessages(from: state)
    }
    return state.writeErrorMessage == nil ? state.document : nil
  }

  /// Returns true once the record is visible in the in-memory projection and
  /// its persistence write has been queued. It does not mean the data is
  /// already durable; callers that need durability must await `flush()`.
  @discardableResult
  private func enqueue(_ mutation: WorkbenchOperationLedgerMutation) -> Bool {
    let date = now()
    let optimistic = mutation.applying(to: document).normalized(now: date)
    document = optimistic
    lastErrorMessage = nil
    revision &+= 1
    let mutationRevision = revision
    let previous = persistenceTail
    let persistence = persistence

    let next = Task.detached(priority: .utility) {
      let previousState = await previous.value
      let candidate = mutation.applying(to: previousState.document).normalized(now: date)
      do {
        try persistence.save(candidate, now: date)
        return WorkbenchOperationLedgerIOState(
          document: candidate,
          recoveryMessage: previousState.recoveryMessage,
          // A successful replacement ledger makes a previous load failure
          // non-actionable, matching the former synchronous save behavior.
          loadErrorMessage: nil,
          writeErrorMessage: nil
        )
      } catch {
        return WorkbenchOperationLedgerIOState(
          document: candidate,
          recoveryMessage: previousState.recoveryMessage,
          loadErrorMessage: previousState.loadErrorMessage,
          writeErrorMessage: CoreL10n.format("活动记录保存失败：%@", error.localizedDescription)
        )
      }
    }
    persistenceTail = next
    Task { [weak self] in
      let state = await next.value
      self?.completeMutation(revision: mutationRevision, state: state)
    }
    return true
  }

  private func applyInitialLoad(_ state: WorkbenchOperationLedgerIOState) {
    guard revision == 0 else { return }
    document = state.document
    applyMessages(from: state)
  }

  private func completeMutation(
    revision mutationRevision: UInt64,
    state: WorkbenchOperationLedgerIOState
  ) {
    // Older disk completions may arrive after newer edits have already been
    // projected to the UI. They are intentionally ignored here; each queued
    // worker still feeds its result into the following worker.
    guard mutationRevision == revision else { return }
    document = state.document
    applyMessages(from: state)
  }

  private func applyMessages(from state: WorkbenchOperationLedgerIOState) {
    recoveryMessage = state.recoveryMessage
    lastErrorMessage = state.writeErrorMessage ?? state.loadErrorMessage
  }

  private static func makeInitialLoadTask(
    persistence: WorkbenchOperationLedgerPersistence,
    now: @escaping @Sendable () -> Date
  ) -> Task<WorkbenchOperationLedgerIOState, Never> {
    Task.detached(priority: .utility) {
      do {
        let result = try persistence.loadWithRecovery(now: now())
        return WorkbenchOperationLedgerIOState(
          document: result.document,
          recoveryMessage: result.recoveryMessage,
          loadErrorMessage: nil,
          writeErrorMessage: nil
        )
      } catch {
        let quarantineDescription: String
        do {
          let quarantined = try persistence.quarantineUnreadableFiles()
          quarantineDescription =
            quarantined.isEmpty
            ? CoreL10n.text("原文件未发生变化。")
            : CoreL10n.format("已隔离 %d 个无法读取的文件。", quarantined.count)
        } catch {
          quarantineDescription = CoreL10n.text("无法隔离原文件，后续记录可能失败。")
        }
        return WorkbenchOperationLedgerIOState(
          document: .init(),
          recoveryMessage: nil,
          loadErrorMessage: CoreL10n.format(
            "活动记录已使用空白账本启动：%@ %@",
            error.localizedDescription,
            quarantineDescription
          ),
          writeErrorMessage: nil
        )
      }
    }
  }
}
