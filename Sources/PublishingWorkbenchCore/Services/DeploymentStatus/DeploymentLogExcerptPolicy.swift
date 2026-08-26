import Foundation

enum DeploymentLogExcerptPolicy {
  static let maximumEntryCount = 32
  static let maximumMessageLength = 2_000
  static let maximumSourceLength = 160
  static let maximumPathLength = 512

  static func boundedEntries(_ entries: [DeploymentLogEntry]) -> [DeploymentLogEntry] {
    entries.prefix(maximumEntryCount).map { entry in
      DeploymentLogEntry(
        id: entry.id,
        level: entry.level,
        source: entry.source,
        message: entry.message,
        filePath: entry.filePath,
        line: entry.line,
        column: entry.column,
        stepName: entry.stepName
      )
    }
  }

  static func boundedSource(_ source: String) -> String {
    bounded(redacted(source), maximumCount: maximumSourceLength)
  }

  static func boundedPath(_ path: String) -> String {
    bounded(redacted(path), maximumCount: maximumPathLength)
  }

  static func redactedAndBoundedMessage(_ message: String) -> String {
    bounded(redacted(message), maximumCount: maximumMessageLength)
  }

  static func entry(
    level: DeploymentLogLevel,
    source: String,
    message: String,
    filePath: String? = nil,
    line: Int? = nil,
    column: Int? = nil,
    stepName: String? = nil
  ) -> DeploymentLogEntry? {
    let trimmedMessage = message
      .replacingOccurrences(of: "\0", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedMessage.isEmpty else {
      return nil
    }

    let inferred = filePath == nil ? inferredLocation(in: trimmedMessage) : nil
    return DeploymentLogEntry(
      level: level,
      source: source,
      message: trimmedMessage,
      filePath: filePath ?? inferred?.filePath,
      line: line ?? inferred?.line,
      column: column ?? inferred?.column,
      stepName: stepName
    )
  }

  static func inferredLocation(in message: String) -> (filePath: String, line: Int, column: Int?)? {
    // Covers common SSG/compiler diagnostics such as
    // `content/posts/article.md:42:7` without assuming a particular SSG.
    guard let regex = try? NSRegularExpression(
      pattern: #"(?:^|[\s(])((?:\.{0,2}/)?[A-Za-z0-9_./-]+\.[A-Za-z0-9_-]+):(\d+)(?::(\d+))?"#
    ) else {
      return nil
    }
    let range = NSRange(message.startIndex..<message.endIndex, in: message)
    guard let match = regex.firstMatch(in: message, range: range), match.numberOfRanges >= 3,
          let fileRange = Range(match.range(at: 1), in: message),
          let lineRange = Range(match.range(at: 2), in: message),
          let line = Int(message[lineRange]) else {
      return nil
    }
    var column: Int?
    if match.numberOfRanges > 3,
       let columnRange = Range(match.range(at: 3), in: message) {
      column = Int(message[columnRange])
    }
    return (String(message[fileRange]), line, column)
  }

  private static func bounded(_ value: String, maximumCount: Int) -> String {
    guard value.count > maximumCount else {
      return value
    }
    let suffix = "…"
    let prefixCount = max(0, maximumCount - suffix.count)
    return String(value.prefix(prefixCount)) + suffix
  }

  private static func redacted(_ value: String) -> String {
    var result = value
    let patterns = [
      #"(?i)\bbearer\s+(?!token\b)[A-Za-z0-9._~+/=-]+"#,
      #"(?i)\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|vercel_[A-Za-z0-9_]+)\b"#,
      #"(?i)\b(?:authorization|access_token|api[_-]?key|token|secret)\s*[:=]\s*[^\s,;]+"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else {
        continue
      }
      let range = NSRange(result.startIndex..<result.endIndex, in: result)
      result = regex.stringByReplacingMatches(
        in: result,
        range: range,
        withTemplate: "<redacted>"
      )
    }
    return result
  }
}

enum VercelDeploymentLogParser {
  static func parse(data: Data) -> [DeploymentLogEntry] {
    if let object = try? JSONSerialization.jsonObject(with: data),
       let events = eventObjects(from: object) {
      return DeploymentLogExcerptPolicy.boundedEntries(events.compactMap(parseEvent))
    }

    // Some proxy/API versions stream one JSON object per line. Keep support
    // for that shape without treating arbitrary text as an unbounded log.
    let lines = String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline) ?? []
    let parsed = lines.compactMap { line -> DeploymentLogEntry? in
      guard let lineData = String(line).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: lineData) else {
        return nil
      }
      return (object as? [String: Any]).flatMap(parseEvent)
    }
    return DeploymentLogExcerptPolicy.boundedEntries(parsed)
  }

  private static func eventObjects(from object: Any) -> [[String: Any]]? {
    if let events = object as? [[String: Any]] {
      return events
    }
    guard let dictionary = object as? [String: Any] else {
      return nil
    }
    for key in ["events", "data", "logs"] {
      if let events = dictionary[key] as? [[String: Any]] {
        return events
      }
    }
    return [dictionary]
  }

  private static func parseEvent(_ event: [String: Any]) -> DeploymentLogEntry? {
    let type = stringValue(in: event, keys: ["type", "level", "kind", "event"])
      .flatMap { $0.trimmedForPublishing.nilIfEmpty }
      ?? "stdout"
    let payload = event["payload"] ?? event["data"]
    let message = stringValue(in: event, keys: ["text", "message", "output", "line", "reason"])
      ?? stringValue(in: payload, keys: ["text", "message", "output", "line", "reason", "value"])
      ?? (payload as? String)
      ?? exitMessage(type: type, payload: payload, event: event)
    guard let message else {
      return nil
    }

    let normalizedType = type.lowercased()
    let level: DeploymentLogLevel
    switch normalizedType {
    case "fatal", "stderr", "error", "failed", "failure", "build-error", "build_error":
      level = .error
    case "warning", "warn":
      level = .warning
    case "exit":
      level = exitCode(in: payload, event: event).map { $0 == 0 ? .info : .error } ?? .error
    default:
      level = .info
    }

    let source = "Vercel · \(DeploymentLogExcerptPolicy.boundedSource(type))"
    return DeploymentLogExcerptPolicy.entry(
      level: level,
      source: source,
      message: message,
      filePath: stringValue(in: event, keys: ["path", "file", "filePath"]),
      line: integerValue(in: event, keys: ["line", "startLine", "start_line"]),
      column: integerValue(in: event, keys: ["column", "startColumn", "start_column"])
    )
  }

  private static func stringValue(in value: Any?, keys: [String]) -> String? {
    if let string = value as? String {
      return string
    }
    guard let dictionary = value as? [String: Any] else {
      return nil
    }
    for key in keys {
      if let string = dictionary[key] as? String, !string.isEmpty {
        return string
      }
    }
    return nil
  }

  private static func integerValue(in value: Any?, keys: [String]) -> Int? {
    guard let dictionary = value as? [String: Any] else {
      return nil
    }
    for key in keys {
      if let integer = dictionary[key] as? Int {
        return integer
      }
      if let number = dictionary[key] as? NSNumber {
        return number.intValue
      }
      if let string = dictionary[key] as? String, let integer = Int(string) {
        return integer
      }
    }
    return nil
  }

  private static func exitCode(in payload: Any?, event: [String: Any]) -> Int? {
    integerValue(in: payload, keys: ["code", "exitCode", "exit_code", "status"])
      ?? integerValue(in: event, keys: ["code", "exitCode", "exit_code", "status"])
  }

  private static func exitMessage(type: String, payload: Any?, event: [String: Any]) -> String? {
    guard type.lowercased() == "exit", let code = exitCode(in: payload, event: event) else {
      return nil
    }
    return "进程退出，代码 \(code)"
  }
}
