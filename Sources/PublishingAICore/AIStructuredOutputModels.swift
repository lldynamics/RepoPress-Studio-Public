import Foundation

/// A Sendable, Codable JSON value shared by function parameter schemas and
/// structured output schemas.
public indirect enum AIStructuredOutputJSONValue: Codable, Hashable, Sendable {
  case object([String: AIStructuredOutputJSONValue])
  case array([AIStructuredOutputJSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([AIStructuredOutputJSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: AIStructuredOutputJSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.typeMismatch(
        AIStructuredOutputJSONValue.self,
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Expected a JSON-compatible schema value."
        )
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    }
  }
}

public struct AIStructuredOutputJSONSchema: Codable, Hashable, Sendable {
  public var name: String
  public var description: String?
  public var schema: AIStructuredOutputJSONValue
  public var strict: Bool?

  public init(
    name: String,
    description: String? = nil,
    schema: AIStructuredOutputJSONValue,
    strict: Bool? = nil
  ) {
    self.name = name
    self.description = description
    self.schema = schema
    self.strict = strict
  }
}

/// OpenAI-compatible Chat Completions `response_format`.
public enum AIStructuredOutputFormat: Codable, Hashable, Sendable {
  case text
  case jsonObject
  case jsonSchema(AIStructuredOutputJSONSchema)

  private enum CodingKeys: String, CodingKey {
    case type
    case jsonSchema = "json_schema"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .type) {
    case "text":
      self = .text
    case "json_object":
      self = .jsonObject
    case "json_schema":
      self = .jsonSchema(
        try container.decode(AIStructuredOutputJSONSchema.self, forKey: .jsonSchema)
      )
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "Unsupported OpenAI-compatible response format."
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text:
      try container.encode("text", forKey: .type)
    case .jsonObject:
      try container.encode("json_object", forKey: .type)
    case .jsonSchema(let schema):
      try container.encode("json_schema", forKey: .type)
      try container.encode(schema, forKey: .jsonSchema)
    }
  }
}
