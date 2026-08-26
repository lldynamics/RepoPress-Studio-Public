import Foundation

/// An OpenAI-compatible function tool declaration. Declaring a tool does not
/// authorize or execute it; execution belongs to a higher-level agent runtime.
public struct AIToolDefinition: Codable, Hashable, Sendable {
  public var type: String
  public var function: AIToolFunctionDefinition

  public init(
    type: String = "function",
    function: AIToolFunctionDefinition
  ) {
    self.type = type
    self.function = function
  }
}

public struct AIToolFunctionDefinition: Codable, Hashable, Sendable {
  public var name: String
  public var description: String?
  public var parameters: AIStructuredOutputJSONValue
  public var strict: Bool?

  public init(
    name: String,
    description: String? = nil,
    parameters: AIStructuredOutputJSONValue,
    strict: Bool? = nil
  ) {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.strict = strict
  }
}

/// OpenAI-compatible `tool_choice`, represented either by a mode string or a
/// specific function selector.
public enum AIToolChoice: Codable, Hashable, Sendable {
  case none
  case auto
  case required
  case function(name: String)

  private enum CodingKeys: String, CodingKey {
    case type
    case function
  }

  private enum FunctionCodingKeys: String, CodingKey {
    case name
  }

  public init(from decoder: Decoder) throws {
    let singleValueContainer = try decoder.singleValueContainer()
    if let mode = try? singleValueContainer.decode(String.self) {
      switch mode {
      case "none":
        self = .none
      case "auto":
        self = .auto
      case "required":
        self = .required
      default:
        throw DecodingError.dataCorruptedError(
          in: singleValueContainer,
          debugDescription: "Unsupported OpenAI-compatible tool choice mode."
        )
      }
      return
    }

    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    guard type == "function" else {
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "Only function tool choices are supported."
      )
    }
    let functionContainer = try container.nestedContainer(
      keyedBy: FunctionCodingKeys.self,
      forKey: .function
    )
    self = .function(name: try functionContainer.decode(String.self, forKey: .name))
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .none:
      var container = encoder.singleValueContainer()
      try container.encode("none")
    case .auto:
      var container = encoder.singleValueContainer()
      try container.encode("auto")
    case .required:
      var container = encoder.singleValueContainer()
      try container.encode("required")
    case .function(let name):
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode("function", forKey: .type)
      var functionContainer = container.nestedContainer(
        keyedBy: FunctionCodingKeys.self,
        forKey: .function
      )
      try functionContainer.encode(name, forKey: .name)
    }
  }
}

/// A complete assistant function call. `arguments` remains a JSON string so a
/// later executor can validate it against the declared schema before use.
public struct AIToolCall: Codable, Hashable, Sendable {
  public var id: String
  public var type: String
  public var function: AIToolFunctionCall

  public init(
    id: String,
    type: String = "function",
    function: AIToolFunctionCall
  ) {
    self.id = id
    self.type = type
    self.function = function
  }
}

public struct AIToolFunctionCall: Codable, Hashable, Sendable {
  public var name: String
  public var arguments: String

  public init(name: String, arguments: String) {
    self.name = name
    self.arguments = arguments
  }
}

/// One OpenAI-compatible streaming `tool_calls` fragment. Fields other than
/// `index` are optional because providers commonly send them across separate
/// chunks.
public struct AIToolCallDelta: Codable, Hashable, Sendable {
  public var index: Int
  public var id: String?
  public var type: String?
  public var function: AIToolFunctionCallDelta?

  public init(
    index: Int,
    id: String? = nil,
    type: String? = nil,
    function: AIToolFunctionCallDelta? = nil
  ) {
    self.index = index
    self.id = id
    self.type = type
    self.function = function
  }
}

public struct AIToolFunctionCallDelta: Codable, Hashable, Sendable {
  public var name: String?
  public var arguments: String?

  public init(name: String? = nil, arguments: String? = nil) {
    self.name = name
    self.arguments = arguments
  }
}

package struct AIToolCallStreamAccumulator: Sendable {
  private struct PartialCall: Sendable {
    var id = ""
    var type = ""
    var name = ""
    var arguments = ""

    var toolCall: AIToolCall {
      AIToolCall(
        id: id,
        type: type.isEmpty ? "function" : type,
        function: AIToolFunctionCall(name: name, arguments: arguments)
      )
    }
  }

  private var callsByIndex: [Int: PartialCall] = [:]

  package init() {}

  package mutating func append(_ deltas: [AIToolCallDelta]) {
    for delta in deltas {
      var call = callsByIndex[delta.index] ?? PartialCall()
      if let id = delta.id {
        call.id.append(id)
      }
      if let type = delta.type {
        // Unlike id/name/arguments, the protocol sends `type` as a complete
        // discriminator. Keep the first value if a compatible provider repeats it.
        if call.type.isEmpty {
          call.type = type
        }
      }
      if let name = delta.function?.name {
        call.name.append(name)
      }
      if let arguments = delta.function?.arguments {
        call.arguments.append(arguments)
      }
      callsByIndex[delta.index] = call
    }
  }

  package var toolCalls: [AIToolCall] {
    callsByIndex.keys.sorted().compactMap { callsByIndex[$0]?.toolCall }
  }
}
