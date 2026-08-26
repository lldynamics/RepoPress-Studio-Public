import Foundation

package enum HTTPErrorResponseSanitizer {
  package static let maximumCharacterCount = 2_000

  package static func sanitize(
    data: Data,
    sensitiveValues: [String] = []
  ) -> String {
    // Decode only a bounded prefix. URLSession has already materialized the
    // response Data, but diagnostics should not create another unbounded String.
    let prefix = data.prefix(maximumCharacterCount * 4)
    return sanitize(
      text: String(decoding: prefix, as: UTF8.self),
      sensitiveValues: sensitiveValues,
      sourceWasTruncated: prefix.count < data.count
    )
  }

  package static func sanitize(
    text: String,
    sensitiveValues: [String] = []
  ) -> String {
    sanitize(text: text, sensitiveValues: sensitiveValues, sourceWasTruncated: false)
  }

  private static func sanitize(
    text: String,
    sensitiveValues: [String],
    sourceWasTruncated: Bool
  ) -> String {
    var sanitized = text
    for value in sensitiveValues
      .map(\.trimmedForPublishing)
      .filter({ $0.count >= 4 })
      .sorted(by: { $0.count > $1.count }) {
      sanitized = sanitized.replacingOccurrences(of: value, with: "[REDACTED]")
    }

    sanitized = replacingMatches(
      in: sanitized,
      pattern: #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#,
      template: "$1[REDACTED]"
    )
    sanitized = replacingMatches(
      in: sanitized,
      pattern: #"(?i)([\"']?(?:authorization|api[_-]?key|access[_-]?token|private[_-]?token|client[_-]?secret|token|secret|password)[\"']?\s*[:=]\s*)[\"']?[^\"'\s,}\]]{4,}[\"']?"#,
      template: "$1\"[REDACTED]\""
    )
    sanitized = replacingMatches(
      in: sanitized,
      pattern: #"\b(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{8,}|glpat-[A-Za-z0-9_-]{8,})\b"#,
      template: "[REDACTED]"
    )

    let wasTruncated = sourceWasTruncated || sanitized.count > maximumCharacterCount
    if sanitized.count > maximumCharacterCount {
      sanitized = String(sanitized.prefix(maximumCharacterCount))
    }
    if wasTruncated {
      sanitized += "\n[远端响应已截断]"
    }
    return sanitized.trimmedForPublishing
  }

  private static func replacingMatches(
    in value: String,
    pattern: String,
    template: String
  ) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return value
    }
    let range = NSRange(value.startIndex..., in: value)
    return expression.stringByReplacingMatches(
      in: value,
      range: range,
      withTemplate: template
    )
  }
}
