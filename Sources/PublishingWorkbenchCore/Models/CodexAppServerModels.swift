import Foundation

/// Values used by the JSON-RPC messages exchanged with `codex app-server`.
///
/// The app-server protocol is intentionally modelled without an `Any` escape hatch.  This
/// keeps the protocol boundary `Sendable` and makes it possible to inspect responses without
/// retaining credentials or other process state.
public enum CodexAppServerJSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([CodexAppServerJSONValue])
  case object([String: CodexAppServerJSONValue])

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
    } else if let value = try? container.decode([CodexAppServerJSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: CodexAppServerJSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }

  public subscript(key: String) -> CodexAppServerJSONValue? {
    guard case .object(let object) = self else { return nil }
    return object[key]
  }

  public var objectValue: [String: CodexAppServerJSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public var doubleValue: Double? {
    guard case .number(let value) = self else { return nil }
    return value
  }

  public var intValue: Int? {
    guard let value = doubleValue, value.isFinite else { return nil }
    return Int(exactly: value)
  }

  public var arrayValue: [CodexAppServerJSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }
}

public struct CodexAppServerAccountStatus: Codable, Equatable, Sendable {
  public let isAuthenticated: Bool
  public let accountID: String?
  public let accountType: String?
  public let email: String?
  public let planType: String?

  public init(
    isAuthenticated: Bool,
    accountID: String? = nil,
    accountType: String? = nil,
    email: String? = nil,
    planType: String? = nil
  ) {
    self.isAuthenticated = isAuthenticated
    self.accountID = accountID
    self.accountType = accountType
    self.email = email
    self.planType = planType
  }
}

/// A reasoning effort exposed by a model in the Codex app-server model catalog.
///
/// The value is intentionally kept as a string. App Server may add an effort
/// level without requiring clients to ship an update first.
public struct CodexAppServerReasoningEffortOption: Codable, Equatable, Sendable {
  public let reasoningEffort: String
  public let description: String?

  public init(reasoningEffort: String, description: String? = nil) {
    self.reasoningEffort = Self.trimmed(reasoningEffort)
    self.description = Self.trimmedOptional(description)
  }

  private enum CodingKeys: String, CodingKey {
    case reasoningEffort
    case effort
    case description
  }

  public init(from decoder: Decoder) throws {
    do {
      let singleValue = try decoder.singleValueContainer()
      let value = try singleValue.decode(String.self)
      self.init(reasoningEffort: value)
      return
    } catch {
      // App Server also returns keyed effort objects; decode that shape below.
    }

    let container = try decoder.container(keyedBy: CodingKeys.self)
    let value: String
    if let reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort) {
      value = reasoningEffort
    } else {
      value = try container.decodeIfPresent(String.self, forKey: .effort) ?? ""
    }
    self.init(
      reasoningEffort: value,
      description: try container.decodeIfPresent(String.self, forKey: .description)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(reasoningEffort, forKey: .reasoningEffort)
    try container.encodeIfPresent(description, forKey: .description)
  }

  private static func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func trimmedOptional(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = trimmed(value)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// A model advertised by the authenticated Codex app-server account.
///
/// Most fields have defaults during decoding so older app-server versions and
/// partial catalog entries remain usable. The model and display name fall back
/// to the identifier when omitted.
public struct CodexAppServerModel: Codable, Equatable, Sendable {
  public let id: String
  public let model: String
  public let displayName: String
  public let description: String?
  public let hidden: Bool
  public let defaultReasoningEffort: String?
  public let supportedReasoningEfforts: [CodexAppServerReasoningEffortOption]
  public let inputModalities: [String]
  public let isDefault: Bool
  public let upgrade: String?

  public init(
    id: String,
    model: String? = nil,
    displayName: String? = nil,
    description: String? = nil,
    hidden: Bool = false,
    defaultReasoningEffort: String? = nil,
    supportedReasoningEfforts: [CodexAppServerReasoningEffortOption] = [],
    inputModalities: [String] = ["text", "image"],
    isDefault: Bool = false,
    upgrade: String? = nil
  ) {
    let normalizedID = Self.trimmed(id)
    let normalizedModel = Self.trimmed(model ?? "")
    let resolvedID = normalizedID.isEmpty ? normalizedModel : normalizedID
    let resolvedModel = normalizedModel.isEmpty ? resolvedID : normalizedModel
    let resolvedDisplayName = Self.trimmed(displayName ?? "")
    self.id = resolvedID
    self.model = resolvedModel
    self.displayName = resolvedDisplayName.isEmpty ? resolvedModel : resolvedDisplayName
    self.description = Self.trimmedOptional(description)
    self.hidden = hidden
    self.defaultReasoningEffort = Self.trimmedOptional(defaultReasoningEffort)
    self.supportedReasoningEfforts = supportedReasoningEfforts
    self.inputModalities = inputModalities.compactMap { value in
      let normalized = Self.trimmed(value)
      return normalized.isEmpty ? nil : normalized
    }
    self.isDefault = isDefault
    self.upgrade = Self.trimmedOptional(upgrade)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case model
    case displayName
    case description
    case hidden
    case defaultReasoningEffort
    case supportedReasoningEfforts
    case inputModalities
    case isDefault
    case upgrade
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
    let model = try container.decodeIfPresent(String.self, forKey: .model)
    let displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    self.init(
      id: id,
      model: model,
      displayName: displayName,
      description: try container.decodeIfPresent(String.self, forKey: .description),
      hidden: try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false,
      defaultReasoningEffort: try container.decodeIfPresent(
        String.self,
        forKey: .defaultReasoningEffort
      ),
      supportedReasoningEfforts: try container.decodeIfPresent(
        [CodexAppServerReasoningEffortOption].self,
        forKey: .supportedReasoningEfforts
      ) ?? [],
      inputModalities: try container.decodeIfPresent([String].self, forKey: .inputModalities)
        ?? ["text", "image"],
      isDefault: try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false,
      upgrade: try container.decodeIfPresent(String.self, forKey: .upgrade)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(model, forKey: .model)
    try container.encode(displayName, forKey: .displayName)
    try container.encodeIfPresent(description, forKey: .description)
    try container.encode(hidden, forKey: .hidden)
    try container.encodeIfPresent(defaultReasoningEffort, forKey: .defaultReasoningEffort)
    try container.encode(supportedReasoningEfforts, forKey: .supportedReasoningEfforts)
    try container.encode(inputModalities, forKey: .inputModalities)
    try container.encode(isDefault, forKey: .isDefault)
    try container.encodeIfPresent(upgrade, forKey: .upgrade)
  }

  private static func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func trimmedOptional(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = trimmed(value)
    return trimmed.isEmpty ? nil : trimmed
  }
}

public struct CodexAppServerLoginResult: Codable, Equatable, Sendable {
  public let loginID: String
  public let authURL: URL

  public init(loginID: String, authURL: URL) {
    self.loginID = loginID
    self.authURL = authURL
  }
}

public struct CodexAppServerDeviceCodeLoginResult: Codable, Equatable, Sendable {
  public let loginID: String
  public let verificationURL: URL
  public let userCode: String

  public init(loginID: String, verificationURL: URL, userCode: String) {
    self.loginID = loginID
    self.verificationURL = verificationURL
    self.userCode = userCode
  }
}

public enum CodexAppServerRuntimeSource: String, Codable, Equatable, Sendable {
  case bundled
  case homebrew
  case path
}

public struct CodexAppServerRuntimeStatus: Codable, Equatable, Sendable {
  public let executableURL: URL?
  public let source: CodexAppServerRuntimeSource?
  public let version: String?

  public init(
    executableURL: URL? = nil,
    source: CodexAppServerRuntimeSource? = nil,
    version: String? = nil
  ) {
    self.executableURL = executableURL
    self.source = source
    self.version = version
  }

  public var isAvailable: Bool {
    executableURL != nil
  }
}

public struct CodexAppServerRateLimitWindow: Codable, Equatable, Sendable {
  public let usedPercent: Double?
  public let windowMinutes: Int?
  public let resetsAt: Date?

  public init(
    usedPercent: Double? = nil,
    windowMinutes: Int? = nil,
    resetsAt: Date? = nil
  ) {
    self.usedPercent = usedPercent
    self.windowMinutes = windowMinutes
    self.resetsAt = resetsAt
  }
}

public struct CodexAppServerRateLimits: Codable, Equatable, Sendable {
  public let primary: CodexAppServerRateLimitWindow?
  public let secondary: CodexAppServerRateLimitWindow?
  public let creditsRemaining: Double?
  public let planType: String?

  public init(
    primary: CodexAppServerRateLimitWindow? = nil,
    secondary: CodexAppServerRateLimitWindow? = nil,
    creditsRemaining: Double? = nil,
    planType: String? = nil
  ) {
    self.primary = primary
    self.secondary = secondary
    self.creditsRemaining = creditsRemaining
    self.planType = planType
  }
}

public struct CodexAppServerCompletion: Codable, Equatable, Sendable {
  public let text: String
  public let threadID: String
  public let turnID: String
  public let model: String?
  /// Host-facing dynamic tool calls emitted by this turn. The Codex process
  /// never executes these application commands itself; the workbench Agent
  /// validates and executes them through its own command registry.
  public let toolCalls: [AIToolCall]

  public init(
    text: String,
    threadID: String,
    turnID: String,
    model: String? = nil,
    toolCalls: [AIToolCall] = []
  ) {
    self.text = text
    self.threadID = threadID
    self.turnID = turnID
    self.model = model
    self.toolCalls = toolCalls
  }
}

public enum CodexAppServerError: Error, Equatable, Sendable {
  case executableNotFound
  case processNotRunning
  case processExited
  case endOfStream
  case invalidJSON
  case invalidResponse
  case rpc(code: Int?, message: String)
  case turnFailed(String)
  case turnInterrupted
  case cancelled
  /// The ChatGPT account is not currently eligible for the explicitly bound
  /// data-sharing grant. The user-facing description must stay generic so an
  /// account ID or email can never escape through an error message.
  case accountAuthorizationRequired
}

extension CodexAppServerError {
  /// Semantic timeout sentinel kept in the RPC-shaped representation so
  /// existing exhaustive ``LocalizedError`` mappings remain source
  /// compatible. The message is actionable and deliberately contains no
  /// server URL, login ID, or authentication material.
  public static var loginTimedOut: Self {
    .rpc(
      code: -32_001,
      message: "登录等待超时，请返回 AI 设置重新开始登录。"
    )
  }
}

struct CodexAppServerRPCErrorPayload: Decodable, Sendable {
  let code: Int?
  let message: String?
  let data: CodexAppServerJSONValue?
}

struct CodexAppServerRPCEnvelope: Decodable, Sendable {
  let id: Int?
  let method: String?
  let params: CodexAppServerJSONValue?
  let result: CodexAppServerJSONValue?
  let error: CodexAppServerRPCErrorPayload?
}
