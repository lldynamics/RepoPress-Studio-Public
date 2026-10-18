import Foundation

/// The stored identity of a historical tool call. Built-in tools use the
/// `workbench/<command>` form.
public struct AIAgentToolID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.init(rawValue: rawValue)
  }
}

public enum AIAgentToolExecutionPolicy: String, Codable, Hashable, Sendable {
  case automatic
  case requiresConfirmation
}

/// The outcome of one tool call recorded by the retired Agent loop. New chat
/// replies never create runs; persisted history stays readable.
public enum WorkbenchAIAgentToolRunStatus: String, Codable, Hashable, Sendable {
  case awaitingConfirmation
  case succeeded
  case failed
  case cancelled
  case rejected
}

/// Durable audit metadata for a historical tool run. Raw arguments were never
/// copied into run history.
public struct WorkbenchAIAgentToolRunRecord: Codable, Identifiable, Hashable, Sendable {
  public static let maximumSummaryLength = 512

  public var toolCallID: String
  public var id: String { toolCallID }
  public var toolID: AIAgentToolID
  public var modelToolName: String
  public var executionPolicy: AIAgentToolExecutionPolicy
  public var catalogRevision: String
  public var correlationID: UUID
  public var status: WorkbenchAIAgentToolRunStatus
  public var summary: String
  public var automationStepID: UUID?
  public var targetDraftID: UUID?
  public var targetDraftVersion: Date?
  public var startedAt: Date
  public var completedAt: Date?

  public init(
    toolCallID: String,
    toolID: AIAgentToolID,
    modelToolName: String,
    executionPolicy: AIAgentToolExecutionPolicy,
    catalogRevision: String,
    status: WorkbenchAIAgentToolRunStatus,
    summary: String,
    correlationID: UUID = UUID(),
    automationStepID: UUID? = nil,
    targetDraftID: UUID? = nil,
    targetDraftVersion: Date? = nil,
    startedAt: Date,
    completedAt: Date? = nil
  ) {
    self.toolCallID = toolCallID
    self.toolID = toolID
    self.modelToolName = modelToolName
    self.executionPolicy = executionPolicy
    self.catalogRevision = catalogRevision
    self.correlationID = correlationID
    self.status = status
    self.summary = Self.boundedSummary(summary)
    self.automationStepID = automationStepID
    self.targetDraftID = targetDraftID
    self.targetDraftVersion = targetDraftVersion
    self.startedAt = startedAt
    self.completedAt = completedAt
  }

  /// This is intentionally optional: a persisted external tool must never be
  /// coerced into a Workbench command.
  public var command: WorkbenchAutomationCommandID? {
    Self.command(for: toolID)
  }

  private enum CodingKeys: String, CodingKey {
    case toolCallID
    case toolID
    case modelToolName
    case executionPolicy
    case catalogRevision
    case correlationID
    case command
    case status
    case summary
    case automationStepID
    case targetDraftID
    case targetDraftVersion
    case startedAt
    case completedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    toolCallID = try container.decode(String.self, forKey: .toolCallID)
    automationStepID = try container.decodeIfPresent(UUID.self, forKey: .automationStepID)
    if let toolID = try container.decodeIfPresent(AIAgentToolID.self, forKey: .toolID) {
      self.toolID = toolID
      modelToolName =
        try container.decodeIfPresent(String.self, forKey: .modelToolName) ?? toolID.rawValue
      executionPolicy =
        try container.decodeIfPresent(
          AIAgentToolExecutionPolicy.self,
          forKey: .executionPolicy
        ) ?? .requiresConfirmation
      catalogRevision =
        try container.decodeIfPresent(String.self, forKey: .catalogRevision)
        ?? Self.legacyCatalogRevision
      correlationID =
        try container.decodeIfPresent(UUID.self, forKey: .correlationID)
        ?? automationStepID
        ?? Self.stableLegacyCorrelationID(toolCallID: toolCallID)
    } else {
      let command = try container.decode(WorkbenchAutomationCommandID.self, forKey: .command)
      toolID = Self.toolID(for: command)
      modelToolName = command.rawValue
      executionPolicy = .requiresConfirmation
      catalogRevision = Self.legacyCatalogRevision
      correlationID =
        automationStepID
        ?? Self.stableLegacyCorrelationID(toolCallID: toolCallID)
    }
    status = try container.decode(WorkbenchAIAgentToolRunStatus.self, forKey: .status)
    summary = Self.boundedSummary(try container.decode(String.self, forKey: .summary))
    targetDraftID = try container.decodeIfPresent(UUID.self, forKey: .targetDraftID)
    targetDraftVersion = try container.decodeIfPresent(Date.self, forKey: .targetDraftVersion)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(toolCallID, forKey: .toolCallID)
    try container.encode(toolID, forKey: .toolID)
    try container.encode(modelToolName, forKey: .modelToolName)
    try container.encode(executionPolicy, forKey: .executionPolicy)
    try container.encode(catalogRevision, forKey: .catalogRevision)
    try container.encode(correlationID, forKey: .correlationID)
    try container.encode(status, forKey: .status)
    try container.encode(summary, forKey: .summary)
    try container.encodeIfPresent(automationStepID, forKey: .automationStepID)
    try container.encodeIfPresent(targetDraftID, forKey: .targetDraftID)
    try container.encodeIfPresent(targetDraftVersion, forKey: .targetDraftVersion)
    try container.encode(startedAt, forKey: .startedAt)
    try container.encodeIfPresent(completedAt, forKey: .completedAt)
  }

  /// A fixed legacy namespace prevents collisions with a future external
  /// catalog.
  static let legacyCatalogRevision = "workbench-legacy-v1"

  /// Built-in tools use the `workbench/<command>` identity; anything else is
  /// an external tool and never maps to a Workbench command.
  static func toolID(for command: WorkbenchAutomationCommandID) -> AIAgentToolID {
    AIAgentToolID("workbench/\(command.rawValue)")
  }

  static func command(for toolID: AIAgentToolID) -> WorkbenchAutomationCommandID? {
    let prefix = "workbench/"
    guard toolID.rawValue.hasPrefix(prefix),
      let command = WorkbenchAutomationCommandID(
        rawValue: String(toolID.rawValue.dropFirst(prefix.count)))
    else {
      return nil
    }
    return command
  }

  private static func boundedSummary(_ summary: String) -> String {
    let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > maximumSummaryLength else { return normalized }
    return String(normalized.prefix(maximumSummaryLength - 3)) + "..."
  }

  fileprivate static func stableLegacyCorrelationID(toolCallID: String) -> UUID {
    let bytes = Array(toolCallID.utf8)
    var uuidBytes = [UInt8](repeating: 0, count: 16)
    for (index, byte) in bytes.enumerated() {
      uuidBytes[index % uuidBytes.count] &+= byte &+ UInt8(truncatingIfNeeded: index)
    }
    uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x50
    uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
        uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
        uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
        uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
      ))
  }
}
