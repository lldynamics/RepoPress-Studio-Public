import Foundation
import PublishingCoreSupport

public enum HTMLSourceDiagnosticSeverity: String, Hashable, Sendable {
  case warning
  case error
}

public struct HTMLSourceDiagnostic: Identifiable, Hashable, Sendable {
  public var id: String
  public var severity: HTMLSourceDiagnosticSeverity
  public var title: String
  public var message: String
  public var range: NSRange
  public var line: Int
  public var column: Int

  public init(
    id: String,
    severity: HTMLSourceDiagnosticSeverity,
    title: String,
    message: String,
    range: NSRange,
    line: Int,
    column: Int
  ) {
    self.id = id
    self.severity = severity
    self.title = title
    self.message = message
    self.range = range
    self.line = line
    self.column = column
  }
}

public enum HTMLSourceDiagnosticService {
  private static let maximumDiagnosticCount = 200
  private static let voidTags: Set<String> = [
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
    "meta", "param", "source", "track", "wbr"
  ]

  private static let tagExpression = try? NSRegularExpression(
    pattern: #"<!--[\s\S]*?-->|<!DOCTYPE\b[^>]*>|</?([A-Za-z][A-Za-z0-9:-]*)(?:\s+(?:[^\"'<>]|\"[^\"]*\"|'[^']*')*)?\s*/?>"#,
    options: [.caseInsensitive]
  )

  private static let ignoredExpression = try? NSRegularExpression(
    pattern: #"<!--[\s\S]*?-->|<script\b[\s\S]*?</script\s*>|<style\b[\s\S]*?</style\s*>|\{\{[\s\S]*?\}\}|\{%[\s\S]*?%\}|<%[\s\S]*?%>"#,
    options: [.caseInsensitive]
  )

  public static func diagnostics(in text: String) -> [HTMLSourceDiagnostic] {
    let source = text as NSString
    let fullRange = NSRange(location: 0, length: source.length)
    let ignoredRanges = ignoredExpression?.matches(in: text, range: fullRange).map(\.range) ?? []
    let matches = tagExpression?.matches(in: text, range: fullRange) ?? []
    var stack: [(name: String, range: NSRange)] = []
    var pendingDiagnostics: [PendingDiagnostic] = []
    var ignoredRangeIndex = 0

    for match in matches {
      while ignoredRangeIndex < ignoredRanges.count,
            NSMaxRange(ignoredRanges[ignoredRangeIndex]) <= match.range.location {
        ignoredRangeIndex += 1
      }
      if ignoredRangeIndex < ignoredRanges.count,
         NSIntersectionRange(ignoredRanges[ignoredRangeIndex], match.range).length == match.range.length {
        continue
      }
      let raw = source.substring(with: match.range)
      guard !raw.hasPrefix("<!--"), !raw.lowercased().hasPrefix("<!doctype"),
            match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { continue }
      let name = source.substring(with: match.range(at: 1)).lowercased()
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      let isClosing = trimmed.hasPrefix("</")
      let isSelfClosing = trimmed.hasSuffix("/>") || voidTags.contains(name)
      if isClosing {
        if let last = stack.last, last.name == name {
          stack.removeLast()
        } else {
          let expected = stack.last?.name
          let message = expected.map {
            CoreL10n.format("这里关闭了 <%@>，但当前等待 </%@>。", name, $0)
          } ?? CoreL10n.format("</%@> 没有对应的开始标签。", name)
          pendingDiagnostics.append(PendingDiagnostic(
            id: "html-closing-\(name)-\(match.range.location)",
            severity: .error,
            title: CoreL10n.text("HTML 标签顺序不匹配"),
            message: message,
            range: match.range
          ))
          if let matchingIndex = stack.lastIndex(where: { $0.name == name }) {
            for item in stack.suffix(from: stack.index(after: matchingIndex))
              where pendingDiagnostics.count < maximumDiagnosticCount {
              pendingDiagnostics.append(PendingDiagnostic(
                id: "html-unclosed-\(item.name)-\(item.range.location)",
                severity: .warning,
                title: CoreL10n.text("HTML 标签没有闭合"),
                message: CoreL10n.format("<%@> 缺少对应的 </%@>。", item.name, item.name),
                range: item.range
              ))
            }
            stack.removeSubrange(matchingIndex...)
          }
        }
      } else if !isSelfClosing {
        stack.append((name, match.range))
      }
      if pendingDiagnostics.count >= maximumDiagnosticCount {
        break
      }
    }

    if pendingDiagnostics.count < maximumDiagnosticCount {
      pendingDiagnostics.append(contentsOf: stack.prefix(maximumDiagnosticCount - pendingDiagnostics.count).map { item in
        PendingDiagnostic(
          id: "html-unclosed-\(item.name)-\(item.range.location)",
          severity: .warning,
          title: CoreL10n.text("HTML 标签没有闭合"),
          message: CoreL10n.format("<%@> 缺少对应的 </%@>。", item.name, item.name),
          range: item.range
        )
      })
    }
    let locationIndex = SourceLocationIndex(source: source)
    let diagnostics = pendingDiagnostics.map {
      makeDiagnostic($0, locationIndex: locationIndex)
    }
    return diagnostics.sorted {
      if $0.range.location == $1.range.location { return $0.id < $1.id }
      return $0.range.location < $1.range.location
    }
  }

  private static func makeDiagnostic(
    _ pending: PendingDiagnostic,
    locationIndex: SourceLocationIndex
  ) -> HTMLSourceDiagnostic {
    let location = locationIndex.location(for: pending.range.location)
    return HTMLSourceDiagnostic(
      id: pending.id,
      severity: pending.severity,
      title: pending.title,
      message: pending.message,
      range: pending.range,
      line: location.line,
      column: location.column
    )
  }

  private struct PendingDiagnostic {
    let id: String
    let severity: HTMLSourceDiagnosticSeverity
    let title: String
    let message: String
    let range: NSRange
  }

  private struct SourceLocationIndex {
    let sourceLength: Int
    let lineStarts: [Int]

    init(source: NSString) {
      sourceLength = source.length
      var starts = [0]
      var index = 0
      while index < source.length {
        let character = source.character(at: index)
        if character == 13 {
          if index + 1 < source.length, source.character(at: index + 1) == 10 {
            index += 1
          }
          starts.append(index + 1)
        } else if character == 10 {
          starts.append(index + 1)
        }
        index += 1
      }
      lineStarts = starts
    }

    func location(for rawLocation: Int) -> (line: Int, column: Int) {
      let location = min(max(rawLocation, 0), sourceLength)
      var lowerBound = 0
      var upperBound = lineStarts.count
      while lowerBound < upperBound {
        let midpoint = (lowerBound + upperBound) / 2
        if lineStarts[midpoint] <= location {
          lowerBound = midpoint + 1
        } else {
          upperBound = midpoint
        }
      }
      let lineIndex = max(0, lowerBound - 1)
      return (lineIndex + 1, location - lineStarts[lineIndex] + 1)
    }
  }
}
