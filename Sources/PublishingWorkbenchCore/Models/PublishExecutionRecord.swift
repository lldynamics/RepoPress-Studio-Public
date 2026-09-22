import Foundation

/// Frozen bytes, media fingerprints and destination accepted for one attempt.
/// Credentials are deliberately supplied at execution time, never persisted.
public struct PublishExecutionPlan: Codable, Hashable, Sendable {
  public let package: PublishPackage
  public let batchItems: [BatchPublishPlanItem]
  public let target: RemoteRepositoryPublishTargetSnapshot
  public let branchName: String
  public let contentSHA256ByPath: [String: String]
  public let gitBlobSHAByPath: [String: String]

  public var draftIDs: Set<UUID> {
    batchItems.isEmpty ? [package.draftID] : Set(batchItems.map(\.draftID))
  }

  func validate() throws {
    let paths = package.files.map(\.repositoryPath)
    let upserts = Set(package.files.filter { $0.operation == .upsert }.map(\.repositoryPath))
    let expectedBranch: String =
      switch target.mode {
      case .directCommit: target.targetBranch
      case .reviewRequest: package.reviewBranchName
      case .previewBranch: package.draftPreviewBranchName
      }
    guard !paths.isEmpty, Set(paths).count == paths.count,
      branchName == expectedBranch, !branchName.isEmpty,
      Set(contentSHA256ByPath.keys) == upserts, Set(gitBlobSHAByPath.keys) == upserts,
      contentSHA256ByPath.values.allSatisfy(WorkbenchRecordPayload.isValidDigest),
      gitBlobSHAByPath.values.allSatisfy({
        $0.utf8.count == 40
          && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
      }),
      package.files.allSatisfy({ file in
        if file.operation == .delete { return true }
        if file.kind == .markdown {
          guard let content = file.content else { return false }
          return WorkbenchRecordPayload.digest(Data(content.utf8))
            == contentSHA256ByPath[file.repositoryPath]
        }
        return file.reviewedSourceSHA256 == contentSHA256ByPath[file.repositoryPath]
      })
    else { throw WorkbenchRecordStorageError.invalidData(CoreL10n.text("发布计划的文件或目标证据不完整。")) }
  }
}

public enum PublishExecutionState: String, Codable, Sendable {
  case awaitingRemoteResult
  case needsVerification
  case remoteAccepted
  case verifiedUnchanged

  public var needsVerification: Bool {
    self == .awaitingRemoteResult || self == .needsVerification
  }

  public var displayName: String {
    switch self {
    case .awaitingRemoteResult: CoreL10n.text("等待远端结果")
    case .needsVerification: CoreL10n.text("待核实远端结果")
    case .remoteAccepted: CoreL10n.text("远端已确认接收")
    case .verifiedUnchanged: CoreL10n.text("已核实未写入")
    }
  }
}

public struct PublishExecutionEvent: Codable, Hashable, Sendable {
  public let stage: RemoteRepositoryPublishProgressStage
  public let date: Date
  public let message: String
}

public struct PublishExecutionRecord: Identifiable, Codable, Hashable, Sendable {
  public let id: UUID
  public let plan: PublishExecutionPlan
  public let createdAt: Date
  public internal(set) var state: PublishExecutionState
  public internal(set) var events: [PublishExecutionEvent]
  public internal(set) var releaseRecordID: UUID?
  public internal(set) var message: String?

  init(id: UUID, plan: PublishExecutionPlan, now: Date = Date()) {
    self.id = id
    self.plan = plan
    createdAt = now
    state = .awaitingRemoteResult
    events = [.init(stage: .preparing, date: now, message: CoreL10n.text("发布计划已保存"))]
  }

  mutating func observe(_ progress: RemoteRepositoryPublishProgress) {
    guard state == .awaitingRemoteResult, events.last?.stage != progress.stage else { return }
    events.append(.init(stage: progress.stage, date: Date(), message: progress.message))
    if events.count > 32 { events.removeSubrange(1..<(events.count - 30)) }
  }

  static func retained(_ records: [Self]) -> [Self] {
    var terminalCount = 0
    return records.filter {
      if $0.state.needsVerification { return true }
      terminalCount += 1
      return terminalCount <= 100
    }
  }
}
