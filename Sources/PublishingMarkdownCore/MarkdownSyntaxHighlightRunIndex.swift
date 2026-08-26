import Foundation

/// Immutable interval index for viewport queries over a syntax snapshot.
/// Results retain the snapshot's original style-application order.
public struct MarkdownSyntaxHighlightRunIndex: Sendable {
  private struct Entry: Sendable {
    let run: MarkdownSyntaxHighlightRun
    let originalIndex: Int
  }

  private let entries: [Entry]
  private let prefixMaximumEnds: [Int]

  public init(runs: [MarkdownSyntaxHighlightRun]) {
    let sortedEntries = runs.enumerated().map { index, run in
      Entry(run: run, originalIndex: index)
    }.sorted { lhs, rhs in
      if lhs.run.range.location == rhs.run.range.location {
        return lhs.originalIndex < rhs.originalIndex
      }
      return lhs.run.range.location < rhs.run.range.location
    }
    entries = sortedEntries

    var maximumEnd = 0
    prefixMaximumEnds = sortedEntries.map { entry in
      maximumEnd = max(maximumEnd, NSMaxRange(entry.run.range))
      return maximumEnd
    }
  }

  public func runs(
    intersecting range: NSRange,
    clippingToIntersection: Bool
  ) -> [MarkdownSyntaxHighlightRun] {
    guard range.location != NSNotFound, range.length > 0 else { return [] }
    let rangeEnd = NSMaxRange(range)

    var upperLowerBound = 0
    var upperUpperBound = entries.count
    while upperLowerBound < upperUpperBound {
      let midpoint = upperLowerBound + ((upperUpperBound - upperLowerBound) / 2)
      if entries[midpoint].run.range.location < rangeEnd {
        upperLowerBound = midpoint + 1
      } else {
        upperUpperBound = midpoint
      }
    }
    let upperIndex = upperLowerBound

    var lowerLowerBound = 0
    var lowerUpperBound = upperIndex
    while lowerLowerBound < lowerUpperBound {
      let midpoint = lowerLowerBound + ((lowerUpperBound - lowerLowerBound) / 2)
      if prefixMaximumEnds[midpoint] <= range.location {
        lowerLowerBound = midpoint + 1
      } else {
        lowerUpperBound = midpoint
      }
    }

    return entries[lowerLowerBound..<upperIndex]
      .compactMap { entry -> (Int, MarkdownSyntaxHighlightRun)? in
        let intersection = NSIntersectionRange(entry.run.range, range)
        guard intersection.length > 0 else { return nil }
        let run = clippingToIntersection
          ? MarkdownSyntaxHighlightRun(style: entry.run.style, range: intersection)
          : entry.run
        return (entry.originalIndex, run)
      }
      .sorted { $0.0 < $1.0 }
      .map { $0.1 }
  }
}
