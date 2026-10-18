import Foundation
import PublishingCoreSupport

extension LocalContentImportService {
  func cleanScalar(_ value: String) -> String {
    let trimmed = value.trimmedForPublishing
    if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""),
      let data = trimmed.data(using: .utf8)
    {
      do {
        return try JSONDecoder().decode(String.self, from: data).trimmedForPublishing
      } catch {
        // Non-JSON YAML/TOML quoting remains a literal scalar; the decoded
        // path above handles the escaped strings produced by our renderer.
        return String(trimmed.dropFirst().dropLast()).trimmedForPublishing
      }
    }
    if trimmed.hasPrefix("'"), trimmed.hasSuffix("'") {
      return String(trimmed.dropFirst().dropLast()).trimmedForPublishing
    }
    return trimmed
  }
  func parseYAMLFrontMatter(_ lines: [String]) -> [String: [String]] {
    var values: [String: [String]] = [:]
    var index = 0

    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmedForPublishing
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
        index += 1
        continue
      }

      guard let separator = trimmed.firstIndex(of: ":") else {
        index += 1
        continue
      }

      let key = String(trimmed[..<separator]).trimmedForPublishing.lowercased()
      let rawValue = String(trimmed[trimmed.index(after: separator)...]).trimmedForPublishing

      if rawValue.isEmpty {
        var listValues: [String] = []
        var lookahead = index + 1
        while lookahead < lines.count {
          let item = lines[lookahead].trimmedForPublishing
          guard item.hasPrefix("- ") else { break }
          listValues.append(cleanScalar(String(item.dropFirst(2))))
          lookahead += 1
        }
        if !listValues.isEmpty {
          values[key] = listValues
          index = lookahead
          continue
        }
      } else {
        values[key] = parseScalarOrArray(rawValue)
      }

      index += 1
    }

    return values
  }

  func parseTOMLFrontMatter(_ lines: [String]) -> [String: [String]] {
    var values: [String: [String]] = [:]

    for line in lines {
      let trimmed = line.trimmedForPublishing
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=")
      else {
        continue
      }

      let key = String(trimmed[..<separator]).trimmedForPublishing.lowercased()
      let rawValue = String(trimmed[trimmed.index(after: separator)...]).trimmedForPublishing
      values[key] = parseScalarOrArray(rawValue)
    }

    return values
  }

  func parseScalarOrArray(_ rawValue: String) -> [String] {
    let value = rawValue.trimmedForPublishing
    if value.hasPrefix("["), value.hasSuffix("]") {
      let inner = String(value.dropFirst().dropLast())
      return
        inner
        .split(separator: ",")
        .map { cleanScalar(String($0)) }
        .filter { !$0.isEmpty }
    }
    return [cleanScalar(value)].filter { !$0.isEmpty }
  }

}
