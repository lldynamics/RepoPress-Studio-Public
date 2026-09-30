import Foundation
import PublishingDomainContracts
import PublishingMarkdownCore

extension AssetResourceManagerService {
  struct ExtractedReference {
    let rawPath: String
    let lineNumber: Int
    let isImageSyntax: Bool
    let tokenUTF16Location: Int
    let tokenUTF16Length: Int
  }

  func extractReferences(text: String, documentPath: String) throws -> [ExtractedReference] {
    let source = text as NSString
    let protectedRanges = MarkdownCodeRangeScanner.scan(text).allRanges
    var references: [ExtractedReference] = []
    let inlinePattern = #"(?m)(!?)\[[^\]]*\]\(\s*(?:<([^>\r\n]+)>|([^\s)\r\n]+))"#
    let definitionPattern = #"(?m)^\s*(!?)\[[^\]\r\n]+\]:\s*(?:<([^>\r\n]+)>|([^\s\r\n]+))"#
    let attributePattern = #"(?i)\b(src|href|poster)\s*=\s*(?:"([^"]+)"|'([^']+)'|([^\s>]+))"#

    for (pattern, isAttribute) in [
      (inlinePattern, false),
      (definitionPattern, false),
      (attributePattern, true),
    ] {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
      for match in matches {
        try Task.checkCancellation()
        guard !protectedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
        else {
          continue
        }
        let pathCaptureIndexes: [Int] = isAttribute ? [2, 3, 4] : [2, 3]
        let pathCaptureIndex = pathCaptureIndexes.first {
          $0 < match.numberOfRanges && match.range(at: $0).location != NSNotFound
        }
        let rawPath = pathCaptureIndex.map { source.substring(with: match.range(at: $0)) }
        guard let rawPath, !rawPath.trimmedForPublishing.isEmpty else { continue }
        let isImageSyntax: Bool
        if isAttribute {
          let attribute = source.substring(with: match.range(at: 1)).lowercased()
          isImageSyntax = attribute != "href"
        } else {
          isImageSyntax =
            match.range(at: 1).location != NSNotFound
            && source.substring(with: match.range(at: 1)) == "!"
        }
        let lineNumber = lineNumber(in: source, atUTF16Offset: match.range.location)
        references.append(
          ExtractedReference(
            rawPath: rawPath,
            lineNumber: lineNumber,
            isImageSyntax: isImageSyntax,
            tokenUTF16Location: pathCaptureIndex.map { match.range(at: $0).location } ?? 0,
            tokenUTF16Length: pathCaptureIndex.map { match.range(at: $0).length } ?? 0
          )
        )
      }
    }

    references.append(contentsOf: try frontMatterReferences(in: text))
    return references
  }

  private func lineNumber(in source: NSString, atUTF16Offset offset: Int) -> Int {
    guard offset > 0 else { return 1 }
    let prefix = source.substring(with: NSRange(location: 0, length: min(offset, source.length)))
    return prefix.utf8.reduce(into: 1) { result, byte in
      if byte == 0x0a { result += 1 }
    }
  }

  private func frontMatterReferences(in text: String) throws -> [ExtractedReference] {
    guard let document = DelimitedFrontMatterParser().split(text) else { return [] }
    let source = text as NSString
    let fieldNames = Set(SiteKind.allCases.map { $0.coverFrontMatterFieldName.lowercased() })
    let fields = fieldNames.sorted().map(NSRegularExpression.escapedPattern(for:)).joined(
      separator: "|")
    let separator = document.delimiter == .yaml ? ":" : "="
    let quotedString = #""(?:\\.|[^"\\])*"|'(?:''|[^'])*'"#
    let pattern =
      "(?im)^[\\t ]*(?:(?:[\\w-]+|\(quotedString))[\\t ]*\\.[\\t ]*)*((?:\(fields))|\(quotedString))[\\t ]*\(separator)[\\t ]*([^\\r\\n]*)"
    let regex = try NSRegularExpression(pattern: pattern)
    let matches = regex.matches(
      in: text, range: NSRange(location: 0, length: document.bodyUTF16Offset))
    var references: [ExtractedReference] = []
    for match in matches {
      try Task.checkCancellation()
      let key = source.substring(with: match.range(at: 1))
      let decodedKey = key.hasPrefix("\"") || key.hasPrefix("'") ? try frontMatterString(key) : key
      guard fieldNames.contains(decodedKey.lowercased()) else { continue }
      let valueRange = match.range(at: 2)
      let rawValue = source.substring(with: valueRange).trimmingCharacters(in: .whitespaces)
      if rawValue.isEmpty || rawValue.hasPrefix("#") {
        // YAML permits indented or indentationless sequences below an empty
        // key. Do not declare this complete without resolving that structure.
        let tail = source.substring(
          with: NSRange(
            location: NSMaxRange(valueRange),
            length: document.bodyUTF16Offset - NSMaxRange(valueRange)))
        let nextLine = tail.components(separatedBy: .newlines).first {
          let line = $0.trimmingCharacters(in: .whitespaces)
          return !line.isEmpty && !line.hasPrefix("#")
        }
        if document.delimiter == .yaml, let nextLine {
          let trimmed = nextLine.trimmingCharacters(in: .whitespaces)
          if trimmed != "---" && trimmed != "..." {
            let indentation = source.substring(with: match.range).prefix { $0 == " " || $0 == "\t" }
              .count
            let nextIndentation = nextLine.prefix { $0 == " " || $0 == "\t" }.count
            let mapping = try NSRegularExpression(
              pattern:
                "^[\\t ]*(?:[\\w.-]+|\(quotedString))[\\t ]*:")
            let nextSource = nextLine as NSString
            let isMapping =
              mapping.firstMatch(
                in: nextLine, range: NSRange(location: 0, length: nextSource.length)) != nil
            var isKnownNestedField = false
            if let nested = regex.firstMatch(
              in: nextLine, range: NSRange(location: 0, length: nextSource.length))
            {
              let key = nextSource.substring(with: nested.range(at: 1))
              let decoded =
                key.hasPrefix("\"") || key.hasPrefix("'") ? try frontMatterString(key) : key
              isKnownNestedField = fieldNames.contains(decoded.lowercased())
            }
            guard isMapping && (nextIndentation <= indentation || isKnownNestedField) else {
              throw AssetResourceManagerError.cleanupReviewChanged
            }
          }
        }
        continue
      }
      // Alias and block-scalar resolution needs a full YAML parser. An
      // unsupported cover expression must never authorize orphan cleanup.
      guard !["*", "&", "|", ">", "{", "!", "\"\"\"", "'''"].contains(where: rawValue.hasPrefix)
      else {
        throw AssetResourceManagerError.cleanupReviewChanged
      }
      if rawValue.hasPrefix("[") {
        let strings = try NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|'(?:''|[^'])*'"#)
        let tokens = strings.matches(in: text, range: valueRange)
        let remaining = NSMutableString(string: source.substring(with: valueRange))
        for token in tokens.reversed() {
          remaining.replaceCharacters(
            in: NSRange(
              location: token.range.location - valueRange.location, length: token.range.length),
            with: "")
        }
        let punctuation = String((remaining as String).prefix { $0 != "#" })
        guard punctuation.trimmingCharacters(in: .whitespaces).hasSuffix("]"),
          punctuation.allSatisfy({ $0.isWhitespace || "[],".contains($0) })
        else {
          throw AssetResourceManagerError.cleanupReviewChanged
        }
        for token in tokens {
          references.append(try frontMatterReference(source: source, token: token.range))
        }
      } else if rawValue.hasPrefix("\"") || rawValue.hasPrefix("'") {
        let strings = try NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|'(?:''|[^'])*'"#)
        guard let token = strings.firstMatch(in: text, range: valueRange) else {
          throw AssetResourceManagerError.cleanupReviewChanged
        }
        references.append(try frontMatterReference(source: source, token: token.range))
      } else {
        let value = source.substring(with: valueRange)
        let scalar = String(value.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
        guard !["null", "~", "false"].contains(scalar.lowercased()), !scalar.isEmpty else {
          continue
        }
        let offset = (value as NSString).range(of: scalar).location
        references.append(
          ExtractedReference(
            rawPath: scalar, lineNumber: lineNumber(in: source, atUTF16Offset: valueRange.location),
            isImageSyntax: true, tokenUTF16Location: valueRange.location + offset,
            tokenUTF16Length: (scalar as NSString).length))
      }
    }
    return references
  }

  private func frontMatterReference(source: NSString, token: NSRange) throws -> ExtractedReference {
    let quoted = source.substring(with: token)
    let path = try frontMatterString(quoted)
    return ExtractedReference(
      rawPath: path, lineNumber: lineNumber(in: source, atUTF16Offset: token.location),
      isImageSyntax: true, tokenUTF16Location: token.location + 1,
      tokenUTF16Length: max(0, token.length - 2))
  }

  private func frontMatterString(_ quoted: String) throws -> String {
    let path: String
    if quoted.hasPrefix("\"") {
      guard let decoded = try? JSONDecoder().decode(String.self, from: Data(quoted.utf8)) else {
        throw AssetResourceManagerError.cleanupReviewChanged
      }
      path = decoded
    } else {
      path = String(quoted.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }
    return path
  }
}
