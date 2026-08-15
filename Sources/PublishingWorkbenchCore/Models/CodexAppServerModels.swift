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

public struct CodexAppServerLoginResult: Codable, Equatable, Sendable {
  public let loginID: String
  public let authURL: URL

  public init(loginID: String, authURL: URL) {
    self.loginID = loginID
    self.authURL = authURL
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

  public init(text: String, threadID: String, turnID: String, model: String? = nil) {
    self.text = text
    self.threadID = threadID
    self.turnID = turnID
    self.model = model
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
