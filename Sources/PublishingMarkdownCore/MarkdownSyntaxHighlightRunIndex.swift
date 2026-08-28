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
    let sortedEntries = Self.sortedEntries(for: runs)
    self.init(sortedEntries: sortedEntries)
  }

  /// Builds an index without sorting when the caller already owns a run list
  /// ordered by increasing UTF-16 location. Runs with equal locations retain
  /// their input order, which remains the style-application order returned by
  /// viewport queries.
  public init(locationSortedRuns runs: [MarkdownSyntaxHighlightRun]) {
    let entries = runs.enumerated().map { index, run in
      Entry(run: run, originalIndex: index)
    }
    self.init(sortedEntries: entries)
  }

  private init(sortedEntries: [Entry]) {
    entries = sortedEntries

    var maximumEnd = 0
    prefixMaximumEnds = sortedEntries.map { entry in
      maximumEnd = max(maximumEnd, NSMaxRange(entry.run.range))
      return maximumEnd
    }
  }

  private static func sortedEntries(for runs: [MarkdownSyntaxHighlightRun]) -> [Entry] {
    runs.enumerated().map { index, run in
      Entry(run: run, originalIndex: index)
    }.sorted { lhs, rhs in
      if lhs.run.range.location == rhs.run.range.location {
        return lhs.originalIndex < rhs.originalIndex
      }
      return lhs.run.range.location < rhs.run.range.location
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

  /// Returns runs whose source spans are affected by a selection. A caret at
  /// either boundary touches the run, matching marker-visibility semantics.
  public func runs(touchedBy selection: NSRange) -> [MarkdownSyntaxHighlightRun] {
    guard selection.location != NSNotFound,
      selection.location >= 0,
      selection.length >= 0
    else { return [] }
    if selection.length > 0 {
      return runs(intersecting: selection, clippingToIntersection: false)
    }

    let candidateStart = max(0, selection.location - 1)
    let candidates = runs(
      intersecting: NSRange(location: candidateStart, length: 2),
      clippingToIntersection: false
    )
    return candidates.filter { run in
      selection.location >= run.range.location
        && selection.location <= NSMaxRange(run.range)
    }
  }
}
