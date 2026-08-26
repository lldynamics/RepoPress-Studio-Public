import Foundation

public enum FrontMatterDelimiter: String, Sendable {
  case yaml = "---"
  case toml = "+++"
}

public struct DelimitedFrontMatterDocument: Equatable, Sendable {
  public let delimiter: FrontMatterDelimiter
  public let frontMatter: String
  public let contentLines: [String]
  public let body: String
  public let bodyUTF16Offset: Int
}

/// Splits YAML and TOML Front Matter with one normalization and offset policy.
public struct DelimitedFrontMatterParser: Sendable {
  public init() {}

  public func split(
    _ source: String,
    expectedDelimiter: FrontMatterDelimiter? = nil
  ) -> DelimitedFrontMatterDocument? {
    let normalized = source
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.components(separatedBy: "\n")
    guard let rawOpening = lines.first?.trimmedForPublishing,
          let delimiter = FrontMatterDelimiter(rawValue: rawOpening),
          expectedDelimiter == nil || expectedDelimiter == delimiter,
          let closingIndex = lines.dropFirst().firstIndex(where: {
            $0.trimmedForPublishing == delimiter.rawValue
          }) else {
      return nil
    }

    let frontMatter = lines[...closingIndex].joined(separator: "\n")
    let sourceText = normalized as NSString
    var bodyOffset = (frontMatter as NSString).length
    var skippedNewlines = 0
    while bodyOffset < sourceText.length,
          skippedNewlines < 2,
          sourceText.character(at: bodyOffset) == 10 {
      bodyOffset += 1
      skippedNewlines += 1
    }

    return DelimitedFrontMatterDocument(
      delimiter: delimiter,
      frontMatter: frontMatter,
      contentLines: Array(lines[1..<closingIndex]),
      body: sourceText.substring(from: bodyOffset),
      bodyUTF16Offset: bodyOffset
    )
  }
}
