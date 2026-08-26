import Foundation

/// Describes the smallest rendering-attribute mutation needed to move a
/// painted syntax viewport. Content and appearance changes can request a full
/// repaint; scrolling can retain the overlapping strip unchanged.
public struct MarkdownSyntaxViewportRenderPlan: Equatable, Sendable {
  public let removalRanges: [NSRange]
  public let applicationSnapshots: [MarkdownSyntaxHighlightSnapshot]

  public init(
    removalRanges: [NSRange],
    applicationSnapshots: [MarkdownSyntaxHighlightSnapshot]
  ) {
    self.removalRanges = removalRanges
    self.applicationSnapshots = applicationSnapshots
  }

  public var affectedUTF16Length: Int {
    removalRanges.reduce(0) { $0 + $1.length }
      + applicationSnapshots.reduce(0) { $0 + $1.range.length }
  }

  public static func make(
    previousPaintedRange: NSRange?,
    currentSnapshot: MarkdownSyntaxHighlightSnapshot,
    requiresFullRepaint: Bool
  ) -> Self {
    let currentRange = normalized(currentSnapshot.range)
    let previousRange = previousPaintedRange.flatMap(normalized)

    if requiresFullRepaint {
      return MarkdownSyntaxViewportRenderPlan(
        removalRanges: previousRange.map { [$0] } ?? [],
        applicationSnapshots: currentRange.map {
          [snapshot(currentSnapshot, clippedTo: $0)]
        } ?? []
      )
    }

    guard let previousRange else {
      return MarkdownSyntaxViewportRenderPlan(
        removalRanges: [],
        applicationSnapshots: currentRange.map {
          [snapshot(currentSnapshot, clippedTo: $0)]
        } ?? []
      )
    }
    guard let currentRange else {
      return MarkdownSyntaxViewportRenderPlan(
        removalRanges: [previousRange],
        applicationSnapshots: []
      )
    }

    let removalRanges = subtract(previousRange, excluding: currentRange)
    let applicationSnapshots = subtract(currentRange, excluding: previousRange).map {
      snapshot(currentSnapshot, clippedTo: $0)
    }
    return MarkdownSyntaxViewportRenderPlan(
      removalRanges: removalRanges,
      applicationSnapshots: applicationSnapshots
    )
  }

  private static func snapshot(
    _ snapshot: MarkdownSyntaxHighlightSnapshot,
    clippedTo range: NSRange
  ) -> MarkdownSyntaxHighlightSnapshot {
    MarkdownSyntaxHighlightSnapshot(
      range: range,
      runs: snapshot.runs.compactMap { run in
        let intersection = NSIntersectionRange(run.range, range)
        guard intersection.length > 0 else { return nil }
        return MarkdownSyntaxHighlightRun(style: run.style, range: intersection)
      }
    )
  }

  private static func subtract(_ range: NSRange, excluding excluded: NSRange) -> [NSRange] {
    let intersection = NSIntersectionRange(range, excluded)
    guard intersection.length > 0 else { return [range] }

    var result: [NSRange] = []
    if range.location < intersection.location {
      result.append(
        NSRange(
          location: range.location,
          length: intersection.location - range.location
        )
      )
    }
    if NSMaxRange(intersection) < NSMaxRange(range) {
      result.append(
        NSRange(
          location: NSMaxRange(intersection),
          length: NSMaxRange(range) - NSMaxRange(intersection)
        )
      )
    }
    return result
  }

  private static func normalized(_ range: NSRange) -> NSRange? {
    guard range.location != NSNotFound,
      range.location >= 0,
      range.length > 0,
      NSMaxRange(range) >= range.location
    else {
      return nil
    }
    return range
  }
}
