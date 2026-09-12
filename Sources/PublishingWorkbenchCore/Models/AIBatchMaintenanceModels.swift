import Foundation

public enum AIBatchMaintenanceOperation: String, Codable, CaseIterable, Identifiable, Sendable {
  case summary
  case tags
  case metadata
  case terminologyReview
  case internalLinksReview

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .summary: return CoreL10n.text("摘要")
    case .tags: return CoreL10n.text("标签")
    case .metadata: return CoreL10n.text("摘要与标签")
    case .terminologyReview: return CoreL10n.text("术语审校")
    case .internalLinksReview: return CoreL10n.text("内部链接审校")
    }
  }
}

public enum AIBatchMaintenanceItemStatus: String, Codable, CaseIterable, Sendable {
  case pending
  case running
  case ready
  case failed
  case applied
  case skipped
}

public struct AIBatchMaintenanceItem: Codable, Identifiable, Hashable, Sendable {
  public let id: UUID
  public let draftID: UUID
  public let draftTitle: String
  public let sourceFingerprint: String
  public var status: AIBatchMaintenanceItemStatus
  public var resultText: String?
  public var errorMessage: String?

  public init(
    id: UUID = UUID(),
    draftID: UUID,
    draftTitle: String,
    sourceFingerprint: String,
    status: AIBatchMaintenanceItemStatus = .pending,
    resultText: String? = nil,
    errorMessage: String? = nil
  ) {
    self.id = id
    self.draftID = draftID
    self.draftTitle = draftTitle
    self.sourceFingerprint = sourceFingerprint
    self.status = status
    self.resultText = resultText
    self.errorMessage = errorMessage
  }
}

public struct AIBatchMaintenanceQueue: Codable, Hashable, Sendable {
  public let id: UUID
  public let siteProfileID: UUID
  public let operation: AIBatchMaintenanceOperation
  public let modelName: String
  public var items: [AIBatchMaintenanceItem]
  public var isPaused: Bool
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    siteProfileID: UUID,
    operation: AIBatchMaintenanceOperation,
    modelName: String,
    items: [AIBatchMaintenanceItem],
    isPaused: Bool = false,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.siteProfileID = siteProfileID
    self.operation = operation
    self.modelName = modelName
    self.items = Self.uniqueCapped(items)
    self.isPaused = isPaused
    self.createdAt = createdAt
  }

  public var totalCount: Int { items.count }
  public var pendingCount: Int { count(.pending) }
  public var runningCount: Int { count(.running) }
  public var readyCount: Int { count(.ready) }
  public var failedCount: Int { count(.failed) }
  public var appliedCount: Int { count(.applied) }
  public var skippedCount: Int { count(.skipped) }
  /// Items with a usable result or an explicit terminal decision.
  public var completedCount: Int { readyCount + appliedCount + skippedCount }
  public var processedCount: Int { completedCount + failedCount }
  public var progressFraction: Double {
    totalCount == 0 ? 1 : Double(processedCount) / Double(totalCount)
  }

  @discardableResult
  public mutating func beginNext(eligibleItemIDs: Set<UUID>? = nil) -> AIBatchMaintenanceItem? {
    guard !isPaused, !items.contains(where: { $0.status == .running }),
      let index = items.firstIndex(where: {
        $0.status == .pending && (eligibleItemIDs?.contains($0.id) ?? true)
      })
    else { return nil }
    items[index].status = .running
    items[index].resultText = nil
    items[index].errorMessage = nil
    return items[index]
  }

  public mutating func complete(id: UUID, resultText: String) {
    guard let index = runningIndex(id) else { return }
    items[index].status = .ready
    items[index].resultText = resultText
    items[index].errorMessage = nil
  }

  public mutating func fail(id: UUID, message: String) {
    guard let index = runningIndex(id) else { return }
    items[index].status = .failed
    items[index].resultText = nil
    items[index].errorMessage = message
  }

  public mutating func pause() { isPaused = true }
  public mutating func resume() { isPaused = false }

  public mutating func retryFailed() {
    for index in items.indices where items[index].status == .failed {
      items[index].status = .pending
      items[index].resultText = nil
      items[index].errorMessage = nil
    }
  }

  public mutating func markApplied(id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }), items[index].status == .ready else {
      return
    }
    items[index].status = .applied
  }

  public mutating func skip(id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }),
      [.pending, .running, .ready, .failed].contains(items[index].status)
    else { return }
    items[index].status = .skipped
    items[index].resultText = nil
    items[index].errorMessage = nil
  }

  /// Requeues work that was interrupted by a process restart and leaves the queue paused.
  public mutating func recoverInterrupted() {
    for index in items.indices where items[index].status == .running {
      items[index].status = .pending
    }
    isPaused = true
  }

  private func count(_ status: AIBatchMaintenanceItemStatus) -> Int {
    items.reduce(into: 0) { if $1.status == status { $0 += 1 } }
  }

  private func runningIndex(_ id: UUID) -> Int? {
    items.firstIndex { $0.id == id && $0.status == .running }
  }

  private static func uniqueCapped(_ items: [AIBatchMaintenanceItem]) -> [AIBatchMaintenanceItem] {
    var seen = Set<UUID>()
    return items.filter { seen.insert($0.draftID).inserted }.prefix(100).map { $0 }
  }

  private enum CodingKeys: String, CodingKey {
    case id, siteProfileID, operation, modelName, items, isPaused, createdAt
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    siteProfileID = try values.decode(UUID.self, forKey: .siteProfileID)
    operation = try values.decode(AIBatchMaintenanceOperation.self, forKey: .operation)
    modelName = try values.decode(String.self, forKey: .modelName)
    items = Self.uniqueCapped(try values.decode([AIBatchMaintenanceItem].self, forKey: .items))
    isPaused = try values.decode(Bool.self, forKey: .isPaused)
    createdAt = try values.decode(Date.self, forKey: .createdAt)
  }
}
