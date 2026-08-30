import CryptoKit
import Foundation
import PublishingAICore
import PublishingWorkbenchCore

typealias PublishingMCPCallResult = WorkbenchAIAgentToolResult

/// Converts one checked MCP discovery snapshot into host-side Agent contracts.
/// A later discovery/configuration must create a new instance, making drift
/// explicit instead of silently updating reviewed calls.
public struct PublishingMCPToolRegistry: WorkbenchAIAgentToolRegistry {
  public let catalog: AIAgentToolCatalogSnapshot
  public let configuration: PublishingMCPSourceConfiguration
  private let toolsByModelName: [String: PublishingMCPDiscoveredTool]
  private let toolsByRemoteName: [String: PublishingMCPDiscoveredTool]

  public init(
    configuration: PublishingMCPSourceConfiguration,
    tools: [PublishingMCPDiscoveredTool]
  ) throws {
    var byModelName: [String: PublishingMCPDiscoveredTool] = [:]
    var byRemoteName: [String: PublishingMCPDiscoveredTool] = [:]
    var descriptors: [AIAgentToolDescriptor] = []
    for tool in tools.sorted(by: { $0.remoteName < $1.remoteName }) {
      try Self.validate(tool: tool, configuration: configuration)
      let modelName = Self.modelVisibleName(
        sourceID: configuration.sourceID,
        remoteToolName: tool.remoteName
      )
      guard byModelName[modelName] == nil,
        byRemoteName.updateValue(tool, forKey: tool.remoteName) == nil
      else {
        throw PublishingMCPClientError.invalidRemoteTool
      }
      byModelName[modelName] = tool
      descriptors.append(
        AIAgentToolDescriptor(
          id: Self.toolID(sourceID: configuration.sourceID, remoteToolName: tool.remoteName),
          definition: AIToolDefinition(
            function: AIToolFunctionDefinition(
              name: modelName,
              description: tool.description,
              parameters: tool.inputSchema,
              strict: nil
            )
          ),
          requiredScopes: configuration.requiredScopes,
          executionPolicy: configuration.executionPolicy
        )
      )
    }
    self.configuration = configuration
    self.toolsByModelName = byModelName
    self.toolsByRemoteName = byRemoteName
    self.catalog = try AIAgentToolCatalogSnapshot(
      revision:
        "mcp-v2/\(configuration.sourceID)/\(configuration.sourceRevision)/\(configuration.configurationDigest)/\(configuration.verifiedAuthorityDigest)/\(Self.catalogDigest(descriptors: descriptors))",
      descriptors: descriptors
    )
  }

  public static func toolID(sourceID: String, remoteToolName: String) -> AIAgentToolID {
    AIAgentToolID("mcp/\(sourceID)/\(remoteToolName)")
  }

  public func prepare(
    call: AIToolCall,
    context _: WorkbenchAIAgentContext
  ) throws -> WorkbenchAIAgentToolInvocation {
    guard call.type == "function",
      !call.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let tool = toolsByModelName[call.function.name],
      let descriptor = catalog.descriptors.first(where: {
        $0.definition.function.name == call.function.name
      }),
      call.function.arguments.utf8.count <= configuration.maximumInputByteCount,
      Self.isJSONObject(call.function.arguments)
    else {
      if toolsByModelName[call.function.name] == nil {
        throw WorkbenchAIAgentToolRegistryError.unknownTool(call.function.name)
      }
      throw WorkbenchAIAgentToolRegistryError.invalidJSON(toolCallID: call.id)
    }

    return WorkbenchAIAgentToolInvocation(
      toolCallID: call.id,
      toolID: descriptor.id,
      modelToolName: descriptor.definition.function.name,
      executionPolicy: descriptor.executionPolicy,
      catalogRevision: catalog.revision,
      externalToolBinding: AIAgentExternalToolBinding(
        sourceID: configuration.sourceID,
        sourceRevision: configuration.sourceRevision,
        remoteToolName: tool.remoteName,
        argumentsJSON: call.function.arguments
      )
    )
  }

  public func revalidate(
    invocation: WorkbenchAIAgentToolInvocation,
    matching call: AIToolCall,
    context: WorkbenchAIAgentContext
  ) throws -> WorkbenchAIAgentToolInvocation {
    let fresh = try prepare(call: call, context: context)
    guard invocation.toolCallID == fresh.toolCallID,
      invocation.toolID == fresh.toolID,
      invocation.modelToolName == fresh.modelToolName,
      invocation.executionPolicy == fresh.executionPolicy,
      invocation.catalogRevision == fresh.catalogRevision,
      invocation.externalToolBinding == fresh.externalToolBinding,
      invocation.automationStep == nil,
      invocation.targetDraftID == nil,
      invocation.targetDraftVersion == nil
    else {
      throw WorkbenchAIAgentToolRegistryError.catalogDrift
    }
    return invocation
  }

  func validatedBinding(
    for invocation: WorkbenchAIAgentToolInvocation
  ) throws -> AIAgentExternalToolBinding {
    guard invocation.catalogRevision == catalog.revision,
      invocation.automationStep == nil,
      invocation.targetDraftID == nil,
      invocation.targetDraftVersion == nil,
      let binding = invocation.externalToolBinding,
      binding.sourceID == configuration.sourceID,
      binding.sourceRevision == configuration.sourceRevision,
      binding.argumentsJSON.utf8.count <= configuration.maximumInputByteCount,
      Self.isJSONObject(binding.argumentsJSON),
      let remoteTool = toolsByRemoteName[binding.remoteToolName],
      let modelTool = toolsByModelName[invocation.modelToolName],
      modelTool.remoteName == remoteTool.remoteName,
      let descriptor = catalog.descriptors.first(where: { $0.id == invocation.toolID }),
      descriptor.definition.function.name == invocation.modelToolName,
      descriptor.executionPolicy == invocation.executionPolicy,
      descriptor.requiredScopes == configuration.requiredScopes,
      invocation.toolID
        == Self.toolID(
          sourceID: configuration.sourceID,
          remoteToolName: remoteTool.remoteName
        )
    else {
      throw PublishingMCPClientError.invocationMismatch
    }
    return binding
  }

  public static func modelVisibleName(sourceID: String, remoteToolName: String) -> String {
    let readable = "mcp_\(normalizedIdentifier(sourceID))_\(normalizedIdentifier(remoteToolName))"
    let suffix = String(stableHash("\(sourceID)\u{1f}\(remoteToolName)"), radix: 16)
    let prefix = String(readable.prefix(64 - suffix.count - 1))
    return "\(prefix)_\(suffix)"
  }

  private static func isJSONObject(_ string: String) -> Bool {
    guard let data = string.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      object is [String: Any]
    else { return false }
    return true
  }

  private static func normalizedIdentifier(_ raw: String) -> String {
    let output = raw.unicodeScalars.map { scalar -> String in
      switch scalar.value {
      case 48...57, 65...90, 97...122:
        return String(scalar).lowercased()
      default:
        return "_"
      }
    }.joined()
    let compact = output.replacingOccurrences(of: "__", with: "_")
    return compact.isEmpty ? "tool" : compact
  }

  private static func stableHash(_ value: String) -> UInt64 {
    value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
      (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
  }

  private static func catalogDigest(
    descriptors: [AIAgentToolDescriptor]
  ) -> String {
    var material = ""
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    func append(_ value: String?) {
      guard let value else {
        material += "-1:"
        return
      }
      material += "\(value.utf8.count):\(value)"
    }
    for descriptor in descriptors.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
      let schema =
        (try? encoder.encode(descriptor.definition.function.parameters))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "invalid"
      append(descriptor.id.rawValue)
      append(descriptor.definition.type)
      append(descriptor.definition.function.name)
      append(descriptor.definition.function.description)
      append(schema)
      append(descriptor.definition.function.strict.map { $0 ? "true" : "false" })
      append(descriptor.requiredScopes.map(\.rawValue).sorted().joined(separator: ","))
      append(descriptor.executionPolicy.rawValue)
    }
    let digest = SHA256.hash(data: Data(material.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func validate(
    tool: PublishingMCPDiscoveredTool,
    configuration: PublishingMCPSourceConfiguration
  ) throws {
    guard tool.remoteName.utf8.count <= 128,
      !tool.remoteName.isEmpty,
      tool.remoteName.unicodeScalars.allSatisfy({ scalar in
        (scalar.value >= 48 && scalar.value <= 57)
          || (scalar.value >= 65 && scalar.value <= 90)
          || (scalar.value >= 97 && scalar.value <= 122)
          || scalar == "-" || scalar == "_" || scalar == "."
      }),
      let data = try? JSONEncoder().encode(tool.inputSchema),
      data.count <= configuration.maximumInputByteCount,
      (tool.description?.utf8.count ?? 0) <= configuration.maximumToolDescriptionByteCount,
      case .object(let object) = tool.inputSchema,
      case .string(let type)? = object["type"], type == "object",
      PublishingMCPJSONSchemaValidator.isSupportedRootSchema(tool.inputSchema)
    else {
      throw PublishingMCPClientError.invalidRemoteTool
    }
  }
}

/// Executes only a reviewed external binding. It never accepts a model-visible
/// function name as authority and it maps MCP result content conservatively.
public actor PublishingMCPToolExecutor {
  private let client: PublishingMCPClient
  private let registry: PublishingMCPToolRegistry

  public init(
    client: PublishingMCPClient,
    registry: PublishingMCPToolRegistry
  ) throws {
    guard client.configuration == registry.configuration else {
      throw PublishingMCPClientError.invalidConfiguration
    }
    self.client = client
    self.registry = registry
  }

  public func execute(
    _ invocation: WorkbenchAIAgentToolInvocation
  ) async throws -> WorkbenchAIAgentToolResult {
    let binding = try registry.validatedBinding(for: invocation)
    return try await client.call(
      remoteToolName: binding.remoteToolName,
      argumentsJSON: binding.argumentsJSON
    )
  }
}
