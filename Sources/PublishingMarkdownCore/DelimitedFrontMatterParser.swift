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
    let sourceText = source as NSString
    let lines = sourceLines(in: sourceText)
    guard let rawOpening = lines.first?.text.trimmedForPublishing,
      let delimiter = FrontMatterDelimiter(rawValue: rawOpening),
      expectedDelimiter == nil || expectedDelimiter == delimiter,
      let closingIndex = lines.dropFirst().firstIndex(where: {
        $0.text.trimmedForPublishing == delimiter.rawValue
      })
    else {
      return nil
    }

    let frontMatter = lines[...closingIndex].map(\.text).joined(separator: "\n")
    var bodyOffset = lines[closingIndex].contentEndUTF16Offset
    var skippedNewlines = 0
    while bodyOffset < sourceText.length,
      skippedNewlines < 2
    {
      let character = sourceText.character(at: bodyOffset)
      guard character == 10 || character == 13 else {
        break
      }

      bodyOffset += 1
      if character == 13,
        bodyOffset < sourceText.length,
        sourceText.character(at: bodyOffset) == 10
      {
        bodyOffset += 1
      }
      skippedNewlines += 1
    }

    return DelimitedFrontMatterDocument(
      delimiter: delimiter,
      frontMatter: frontMatter,
      contentLines: lines[1..<closingIndex].map(\.text),
      body: sourceText.substring(from: bodyOffset),
      bodyUTF16Offset: bodyOffset
    )
  }

  private func sourceLines(in source: NSString) -> [SourceLine] {
    var lines: [SourceLine] = []
    var offset = 0

    while offset < source.length {
      let lineStart = offset
      while offset < source.length {
        let character = source.character(at: offset)
        guard character != 10, character != 13 else {
          break
        }
        offset += 1
      }

      let contentEnd = offset
      if offset < source.length {
        let character = source.character(at: offset)
        offset += 1
        if character == 13,
          offset < source.length,
          source.character(at: offset) == 10
        {
          offset += 1
        }
      }

      lines.append(
        SourceLine(
          text: source.substring(
            with: NSRange(location: lineStart, length: contentEnd - lineStart)),
          contentEndUTF16Offset: contentEnd
        )
      )
    }

    if source.length > 0,
      isLineEnding(source.character(at: source.length - 1))
    {
      lines.append(SourceLine(text: "", contentEndUTF16Offset: source.length))
    }

    return lines
  }

  private func isLineEnding(_ character: unichar) -> Bool {
    character == 10 || character == 13
  }
}

private struct SourceLine {
  let text: String
  let contentEndUTF16Offset: Int
}
