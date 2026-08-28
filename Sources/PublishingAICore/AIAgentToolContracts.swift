import Foundation

/// A stable host-side identity for an Agent tool.
///
/// This identity intentionally remains distinct from the model-visible
/// function name in `AIToolDefinition`.
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

/// The immutable authority-bearing payload needed to route one prepared call
/// back to an external tool source. Display names and model-visible function
/// names must never be used as substitutes for these fields.
public struct AIAgentExternalToolBinding: Codable, Hashable, Sendable {
  public var sourceID: String
  public var sourceRevision: String
  public var remoteToolName: String
  public var argumentsJSON: String

  public init(
    sourceID: String,
    sourceRevision: String,
    remoteToolName: String,
    argumentsJSON: String
  ) {
    self.sourceID = sourceID
    self.sourceRevision = sourceRevision
    self.remoteToolName = remoteToolName
    self.argumentsJSON = argumentsJSON
  }
}

/// A provider-independent description of one executable Agent capability.
public struct AIAgentToolDescriptor: Codable, Hashable, Sendable {
  public var id: AIAgentToolID
  public var definition: AIToolDefinition
  public var requiredScopes: Set<AIAgentPermissionScope>
  public var executionPolicy: AIAgentToolExecutionPolicy

  public init(
    id: AIAgentToolID,
    definition: AIToolDefinition,
    requiredScopes: Set<AIAgentPermissionScope> = [],
    executionPolicy: AIAgentToolExecutionPolicy = .requiresConfirmation
  ) {
    self.id = id
    self.definition = definition
    self.requiredScopes = requiredScopes
    self.executionPolicy = executionPolicy
  }
}

public enum AIAgentToolCatalogValidationError: Error, Equatable, LocalizedError, Sendable {
  case blankRevision
  case blankToolID
  case duplicateToolID(AIAgentToolID)
  case blankFunctionName
  case duplicateFunctionName(String)

  public var errorDescription: String? {
    switch self {
    case .blankRevision:
      return "工具目录版本不能为空。"
    case .blankToolID:
      return "工具 ID 不能为空。"
    case .duplicateToolID(let id):
      return "工具 ID 重复：\(id.rawValue)。"
    case .blankFunctionName:
      return "工具函数名不能为空。"
    case .duplicateFunctionName(let name):
      return "模型可见的工具函数名重复：\(name)。"
    }
  }
}

/// An immutable-in-practice, validated view of the tools available to an Agent.
public struct AIAgentToolCatalogSnapshot: Codable, Hashable, Sendable {
  public let revision: String
  public let descriptors: [AIAgentToolDescriptor]

  public init(
    revision: String,
    descriptors: [AIAgentToolDescriptor]
  ) throws {
    guard !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AIAgentToolCatalogValidationError.blankRevision
    }

    var ids = Set<AIAgentToolID>()
    var functionNames = Set<String>()
    for descriptor in descriptors {
      guard !descriptor.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AIAgentToolCatalogValidationError.blankToolID
      }
      guard ids.insert(descriptor.id).inserted else {
        throw AIAgentToolCatalogValidationError.duplicateToolID(descriptor.id)
      }

      let functionName = descriptor.definition.function.name
      guard !functionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AIAgentToolCatalogValidationError.blankFunctionName
      }
      guard functionNames.insert(functionName).inserted else {
        throw AIAgentToolCatalogValidationError.duplicateFunctionName(functionName)
      }
    }

    self.revision = revision
    self.descriptors = descriptors
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let revision = try container.decode(String.self, forKey: .revision)
    let descriptors = try container.decode([AIAgentToolDescriptor].self, forKey: .descriptors)
    self = try Self(revision: revision, descriptors: descriptors)
  }
}
