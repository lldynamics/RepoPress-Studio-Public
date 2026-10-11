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
}
