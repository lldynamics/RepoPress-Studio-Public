import Foundation

public struct KnowledgeRevisionDifferenceService: Sendable {
  public init() {}

  public func difference(
    previousText: String,
    currentText: String
  ) -> KnowledgeRevisionDifference {
    let previousLines = previousText.components(separatedBy: .newlines)
    let currentLines = currentText.components(separatedBy: .newlines)
    let changes = currentLines.difference(from: previousLines)
    let added = changes.reduce(into: 0) { count, change in
      if case .insert = change { count += 1 }
    }
    let removed = changes.reduce(into: 0) { count, change in
      if case .remove = change { count += 1 }
    }
    let firstChangedLine = firstChangedLineIndex(previousLines, currentLines)

    return KnowledgeRevisionDifference(
      previousLineCount: previousLines.count,
      currentLineCount: currentLines.count,
      addedLineCount: added,
      removedLineCount: removed,
      previousExcerpt: excerpt(previousLines, around: firstChangedLine),
      currentExcerpt: excerpt(currentLines, around: firstChangedLine)
    )
  }

  private func firstChangedLineIndex(_ lhs: [String], _ rhs: [String]) -> Int {
    for index in 0..<min(lhs.count, rhs.count) where lhs[index] != rhs[index] {
      return index
    }
    return min(lhs.count, rhs.count)
  }

  private func excerpt(_ lines: [String], around index: Int) -> String {
    guard !lines.isEmpty else { return "" }
    let lowerBound = max(0, min(index, lines.count - 1) - 4)
    let upperBound = min(lines.count, lowerBound + 12)
    let joined = lines[lowerBound..<upperBound].joined(separator: "\n")
    return joined.count <= 2_400 ? joined : String(joined.prefix(2_400)) + "…"
  }
}
