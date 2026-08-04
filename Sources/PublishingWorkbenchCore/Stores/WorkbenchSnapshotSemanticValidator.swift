import Foundation

enum WorkbenchSnapshotSemanticValidationError: LocalizedError, Equatable, Sendable {
  case profilesEmpty
  case duplicateProfileID(UUID)
  case activeProfileMissing(UUID)
  case duplicateDraftID(UUID)
  case duplicateRecycledDraftID(UUID)
  case activeAndRecycledDraftOverlap(UUID)
  case draftProfileMissing(draftID: UUID, profileID: UUID)
  case versionDraftIDMismatch(versionID: UUID, declaredDraftID: UUID, embeddedDraftID: UUID)
  case editorSessionDraftMissing(UUID)

  var errorDescription: String? {
    switch self {
    case .profilesEmpty:
      return "快照不包含任何站点 Profile。"
    case let .duplicateProfileID(id):
      return "快照包含重复的站点 Profile ID：\(id.uuidString)。"
    case let .activeProfileMissing(id):
      return "活动站点 Profile 不存在：\(id.uuidString)。"
    case let .duplicateDraftID(id):
      return "快照包含重复的草稿 ID：\(id.uuidString)。"
    case let .duplicateRecycledDraftID(id):
      return "回收站包含重复的草稿 ID：\(id.uuidString)。"
    case let .activeAndRecycledDraftOverlap(id):
      return "草稿同时存在于工作区和回收站：\(id.uuidString)。"
    case let .draftProfileMissing(draftID, profileID):
      return "草稿 \(draftID.uuidString) 引用了不存在的站点 Profile：\(profileID.uuidString)。"
    case let .versionDraftIDMismatch(versionID, declaredDraftID, embeddedDraftID):
      return "草稿版本 \(versionID.uuidString) 的草稿 ID 不一致：\(declaredDraftID.uuidString) / \(embeddedDraftID.uuidString)。"
    case let .editorSessionDraftMissing(id):
      return "编辑器会话引用了不存在的草稿：\(id.uuidString)。"
    }
  }
}

enum WorkbenchSnapshotSemanticValidator {
  static func validate(_ snapshot: WorkbenchSnapshot) throws {
    guard !snapshot.profiles.isEmpty else {
      throw WorkbenchSnapshotSemanticValidationError.profilesEmpty
    }

    let profileIDList = snapshot.profiles.map(\.id)
    if let duplicateID = firstDuplicate(in: profileIDList) {
      throw WorkbenchSnapshotSemanticValidationError.duplicateProfileID(duplicateID)
    }

    let profileIDs = Set(profileIDList)
    guard profileIDs.contains(snapshot.activeProfileID) else {
      throw WorkbenchSnapshotSemanticValidationError.activeProfileMissing(snapshot.activeProfileID)
    }

    let draftIDList = snapshot.drafts.map(\.id)
    if let duplicateID = firstDuplicate(in: draftIDList) {
      throw WorkbenchSnapshotSemanticValidationError.duplicateDraftID(duplicateID)
    }

    let recycledDraftIDList = snapshot.recycledDrafts.map(\.id)
    if let duplicateID = firstDuplicate(in: recycledDraftIDList) {
      throw WorkbenchSnapshotSemanticValidationError.duplicateRecycledDraftID(duplicateID)
    }

    let draftIDs = Set(draftIDList)
    let recycledDraftIDs = Set(recycledDraftIDList)
    if let overlappingID = draftIDs.intersection(recycledDraftIDs)
      .sorted(by: uuidSort)
      .first {
      throw WorkbenchSnapshotSemanticValidationError.activeAndRecycledDraftOverlap(overlappingID)
    }

    let allDrafts = snapshot.drafts + snapshot.recycledDrafts.map(\.draft)
    for draft in allDrafts {
      try validateProfileReference(for: draft, profileIDs: profileIDs)
    }

    for version in snapshot.draftVersions {
      guard version.draftID == version.draft.id else {
        throw WorkbenchSnapshotSemanticValidationError.versionDraftIDMismatch(
          versionID: version.id,
          declaredDraftID: version.draftID,
          embeddedDraftID: version.draft.id
        )
      }
      try validateProfileReference(for: version.draft, profileIDs: profileIDs)
    }

    let validEditorSessionDraftIDs = draftIDs.union(recycledDraftIDs)
    if let missingID = snapshot.markdownEditorSessionStates.keys
      .filter({ !validEditorSessionDraftIDs.contains($0) })
      .sorted(by: uuidSort)
      .first {
      throw WorkbenchSnapshotSemanticValidationError.editorSessionDraftMissing(missingID)
    }
  }

  private static func validateProfileReference(
    for draft: ArticleDraft,
    profileIDs: Set<UUID>
  ) throws {
    guard profileIDs.contains(draft.siteProfileID) else {
      throw WorkbenchSnapshotSemanticValidationError.draftProfileMissing(
        draftID: draft.id,
        profileID: draft.siteProfileID
      )
    }
  }

  private static func firstDuplicate(in ids: [UUID]) -> UUID? {
    var seen: Set<UUID> = []
    for id in ids where !seen.insert(id).inserted {
      return id
    }
    return nil
  }

  private static func uuidSort(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString < rhs.uuidString
  }
}

enum WorkbenchRecoveryTransactionError: LocalizedError {
  case stagedDataMismatch(String)
  case stagingFailed(String)
  case archiveFailed(String)
  case backupInstallFailed(String)
  case primaryInstallFailed(String)

  var errorDescription: String? {
    switch self {
    case let .stagedDataMismatch(fileName):
      return "恢复暂存文件与输入快照不一致：\(fileName)。"
    case let .stagingFailed(reason):
      return "恢复快照暂存或复验失败，现有快照未修改：\(reason)"
    case let .archiveFailed(reason):
      return "现有快照归档失败，恢复操作未开始：\(reason)"
    case let .backupInstallFailed(reason):
      return "恢复副本写入失败，主快照未修改：\(reason)"
    case let .primaryInstallFailed(reason):
      return "主快照写入失败；新的有效恢复副本已保留，可在下次启动时恢复：\(reason)"
    }
  }
}

struct WorkbenchRecoveryFileOperations {
  let writeAtomically: (Data, URL) throws -> Void
  let archiveExistingSnapshots: () throws -> URL
}
