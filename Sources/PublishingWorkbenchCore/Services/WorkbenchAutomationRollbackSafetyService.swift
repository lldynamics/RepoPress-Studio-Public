import Foundation

/// The postcondition captured immediately after an Agent mutation.
///
/// A rollback may only be offered when the current draft still proves the
/// exact state produced by the Agent.  The draft ID binds the check to the
/// same object, the content fingerprint detects edits, and the timestamp is
/// an additional exact (never tolerant) guard when it was captured.  A
/// rollback version ID is required for content mutations because the service
/// must never guess which historical version should be restored.
public struct WorkbenchAutomationRollbackPostcondition: Codable, Equatable, Hashable, Sendable {
  public var draftID: UUID?
  public var postMutationFingerprint: String?
  public var postMutationUpdatedAt: Date?
  public var rollbackVersionID: UUID?

  public init(
    draftID: UUID? = nil,
    fingerprint: String? = nil,
    updatedAt: Date? = nil,
    rollbackVersionID: UUID? = nil
  ) {
    self.draftID = draftID
    self.postMutationFingerprint = fingerprint
    self.postMutationUpdatedAt = updatedAt
    self.rollbackVersionID = rollbackVersionID
  }

  /// Captures the stable draft identity and all repository-visible content
  /// after a mutation.  `repositoryContentFingerprint` intentionally excludes
  /// the draft ID and timestamps, so those values remain independently
  /// checked by this service.
  public init(draft: ArticleDraft, rollbackVersionID: UUID? = nil) {
    self.init(
      draftID: draft.id,
      fingerprint: draft.repositoryContentFingerprint,
      updatedAt: draft.updatedAt,
      rollbackVersionID: rollbackVersionID
    )
  }

  public var hasFingerprint: Bool {
    guard let postMutationFingerprint else { return false }
    return !postMutationFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

public enum WorkbenchAutomationRollbackConflictReason: Equatable, Hashable, Sendable {
  case unknownCommand(String)
  case unsupportedCommand(WorkbenchAutomationCommandID)
  case missingPostcondition
  case missingExpectedDraftID
  case missingPostMutationFingerprint
  case missingCurrentDraft
  case draftIdentityMismatch(expected: UUID, actual: UUID)
  case draftFingerprintMismatch(expected: String, actual: String)
  case draftUpdatedAtMismatch(expected: Date, actual: Date)
  case missingRollbackVersionID
  case permanentDeletionForbidden

  public var displayMessage: String {
    switch self {
    case .unknownCommand(let command):
      return "无法安全撤销未知自动化命令“" + command + "”"
    case .unsupportedCommand(let command):
      return "命令“" + command.rawValue + "”没有受支持的安全撤销策略"
    case .missingPostcondition:
      return "缺少 Agent 操作完成后的状态证明，已拒绝撤销"
    case .missingExpectedDraftID:
      return "缺少操作完成后的文章身份，已拒绝撤销"
    case .missingPostMutationFingerprint:
      return "缺少操作完成后的内容指纹，不能仅凭时间判断安全性"
    case .missingCurrentDraft:
      return "目标文章已不存在，无法确认它没有被替换或外部修改"
    case .draftIdentityMismatch(let expected, let actual):
      return "目标文章身份已变化（记录 " + expected.uuidString + "，当前 " + actual.uuidString + "）"
    case .draftFingerprintMismatch:
      return "文章在 Agent 操作后已被编辑，未执行撤销"
    case .draftUpdatedAtMismatch:
      return "文章更新时间已变化，未执行撤销"
    case .missingRollbackVersionID:
      return "缺少修改前版本 ID，无法安全恢复文章版本"
    case .permanentDeletionForbidden:
      return "Agent 创建的文章只能移入回收站，禁止永久删除"
    }
  }
}

public enum WorkbenchAutomationRollbackDecision: Equatable, Hashable, Sendable {
  case safeToMoveCreatedDraftToTrash
  case safeToRestoreVersion
  case conflict(WorkbenchAutomationRollbackConflictReason)

  public var isSafe: Bool {
    switch self {
    case .safeToMoveCreatedDraftToTrash, .safeToRestoreVersion:
      return true
    case .conflict:
      return false
    }
  }

  public var displayMessage: String? {
    guard case .conflict(let reason) = self else { return nil }
    return reason.displayMessage
  }
}

/// Pure, side-effect-free rollback policy for Agent-created mutations.
///
/// The executor still owns the actual move-to-trash/version-restore side
/// effects.  This service only decides whether the recorded postcondition is
/// strong enough and whether the current draft still matches it.
public struct WorkbenchAutomationRollbackSafetyService: Sendable {
  public init() {}

  public static func evaluate(
    command: WorkbenchAutomationCommandID,
    postcondition: WorkbenchAutomationRollbackPostcondition?,
    currentDraft: ArticleDraft?
  ) -> WorkbenchAutomationRollbackDecision {
    switch command {
    case .createDraft:
      break
    case .updateMetadata, .appendToBody, .replaceBody, .applyDiff, .generateFrontmatter:
      break
    default:
      return .conflict(.unsupportedCommand(command))
    }

    guard let postcondition else {
      return .conflict(.missingPostcondition)
    }
    guard let expectedDraftID = postcondition.draftID else {
      return .conflict(.missingExpectedDraftID)
    }
    guard postcondition.hasFingerprint,
      let expectedFingerprint = postcondition.postMutationFingerprint
    else {
      return .conflict(.missingPostMutationFingerprint)
    }
    guard let currentDraft else {
      return .conflict(.missingCurrentDraft)
    }
    guard currentDraft.id == expectedDraftID else {
      return .conflict(
        .draftIdentityMismatch(expected: expectedDraftID, actual: currentDraft.id)
      )
    }

    let actualFingerprint = currentDraft.repositoryContentFingerprint
    guard actualFingerprint == expectedFingerprint else {
      return .conflict(
        .draftFingerprintMismatch(expected: expectedFingerprint, actual: actualFingerprint)
      )
    }
    if let expectedUpdatedAt = postcondition.postMutationUpdatedAt,
      currentDraft.updatedAt != expectedUpdatedAt
    {
      return .conflict(
        .draftUpdatedAtMismatch(expected: expectedUpdatedAt, actual: currentDraft.updatedAt)
      )
    }

    switch command {
    case .createDraft:
      // A newly created draft is reversible only through the normal trash
      // flow.  In particular, this branch deliberately never returns a
      // version-restore decision or authorizes permanent deletion.
      return .safeToMoveCreatedDraftToTrash
    case .updateMetadata, .appendToBody, .replaceBody, .applyDiff, .generateFrontmatter:
      guard postcondition.rollbackVersionID != nil else {
        return .conflict(.missingRollbackVersionID)
      }
      return .safeToRestoreVersion
    default:
      return .conflict(.unsupportedCommand(command))
    }
  }

  /// Raw-value entry point used by persisted records and protocol payloads.
  /// Unknown values fail closed instead of being mapped to a fallback command.
  public static func evaluate(
    rawCommand: String,
    postcondition: WorkbenchAutomationRollbackPostcondition?,
    currentDraft: ArticleDraft?
  ) -> WorkbenchAutomationRollbackDecision {
    guard let command = WorkbenchAutomationCommandID(rawValue: rawCommand) else {
      return .conflict(.unknownCommand(rawCommand))
    }
    return evaluate(
      command: command,
      postcondition: postcondition,
      currentDraft: currentDraft
    )
  }

  public func evaluate(
    command: WorkbenchAutomationCommandID,
    postcondition: WorkbenchAutomationRollbackPostcondition?,
    currentDraft: ArticleDraft?
  ) -> WorkbenchAutomationRollbackDecision {
    Self.evaluate(
      command: command,
      postcondition: postcondition,
      currentDraft: currentDraft
    )
  }
}
