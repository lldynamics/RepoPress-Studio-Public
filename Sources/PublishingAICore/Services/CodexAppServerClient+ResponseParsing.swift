import Foundation

extension CodexAppServerClient {
  func parseRateLimitWindow(_ value: CodexAppServerJSONValue?)
    -> CodexAppServerRateLimitWindow?
  {
    guard let object = value?.objectValue else { return nil }
    let usedPercent =
      object["usedPercent"]?.doubleValue
      ?? object["used"]?.doubleValue
    let windowMinutes =
      object["windowMinutes"]?.intValue
      ?? object["windowDurationMinutes"]?.intValue
      ?? object["windowDurationMins"]?.intValue
    let resetValue = object["resetsAt"] ?? object["resetAt"]
    var resetsAt: Date?
    if let seconds = resetValue?.doubleValue {
      resetsAt = Date(timeIntervalSince1970: seconds)
    } else if let string = resetValue?.stringValue {
      resetsAt = ISO8601DateFormatter().date(from: string)
    }
    return CodexAppServerRateLimitWindow(
      usedPercent: usedPercent,
      windowMinutes: windowMinutes,
      resetsAt: resetsAt
    )
  }

  func identifier(
    in value: CodexAppServerJSONValue,
    nestedKeys: [String]
  ) -> String? {
    guard let root = value.objectValue else { return nil }
    for key in nestedKeys {
      if let string = root[key]?.stringValue {
        return string
      }
      if let nested = root[key]?.objectValue {
        for nestedKey in ["id", "threadId", "threadID", "turnId", "turnID"] {
          if let string = nested[nestedKey]?.stringValue {
            return string
          }
        }
      }
    }
    return nil
  }

  func firstString(
    in object: [String: CodexAppServerJSONValue],
    keys: [String]
  ) -> String? {
    for key in keys {
      if let value = object[key]?.stringValue {
        return value
      }
    }
    return nil
  }

  func firstNonEmptyString(
    in object: [String: CodexAppServerJSONValue],
    keys: [String]
  ) -> String? {
    for key in keys {
      guard let value = object[key]?.stringValue else { continue }
      let trimmed = Self.trimmedNonEmpty(value)
      if let trimmed { return trimmed }
    }
    return nil
  }

  static func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func validatedLoginURL(_ rawValue: String) -> URL? {
    guard let url = URL(string: rawValue),
      url.scheme?.caseInsensitiveCompare("https") == .orderedSame,
      let host = url.host,
      !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      url.user == nil,
      url.password == nil
    else {
      return nil
    }
    return url
  }

  static func sanitizedMessage(_ message: String) -> String {
    let lowercased = message.lowercased()
    if lowercased.contains("bearer ")
      || lowercased.contains("access_token")
      || lowercased.contains("refresh_token")
      || lowercased.contains("api_key")
      || message.contains("eyJ")
    {
      return "Sensitive authentication details omitted."
    }
    return String(message.prefix(512))
  }

  static func mapError(_ error: Error) -> CodexAppServerError {
    if let error = error as? CodexAppServerError {
      return error
    }
    if error is CancellationError {
      return .cancelled
    }
    return .processExited
  }
}
