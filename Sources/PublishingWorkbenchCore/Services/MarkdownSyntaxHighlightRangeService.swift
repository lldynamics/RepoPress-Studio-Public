import Foundation

public struct MarkdownSyntaxHighlightPlan: Hashable, Sendable {
  public var range: NSRange
  public var codeBlockRanges: [NSRange]?

  public init(range: NSRange, codeBlockRanges: [NSRange]? = nil) {
    self.range = range
    self.codeBlockRanges = codeBlockRanges
  }

  public static func fullDocument(for markdown: String) -> Self {
    MarkdownSyntaxHighlightPlan(
      range: NSRange(location: 0, length: (markdown as NSString).length)
    )
  }
}

public enum MarkdownSyntaxHighlightSchedulingPolicy {
  public static let localEditDelay: TimeInterval = 0.045
  public static let expensiveEditDelay: TimeInterval = 0.12
  public static let maximumLocalEditUTF16Length = 4_096

  public static func delay(
    for plan: MarkdownSyntaxHighlightPlan,
    documentUTF16Length: Int
  ) -> TimeInterval {
    let range = plan.range
    guard documentUTF16Length >= 0,
          range.location != NSNotFound,
          range.location >= 0,
          range.length >= 0,
          range.location <= documentUTF16Length,
          range.length <= documentUTF16Length - range.location,
          plan.codeBlockRanges != nil else {
      return expensiveEditDelay
    }

    let fullDocumentRange = NSRange(location: 0, length: documentUTF16Length)
    guard range != fullDocumentRange,
          range.length <= maximumLocalEditUTF16Length else {
      return expensiveEditDelay
    }
    return localEditDelay
  }
}

public enum MarkdownSyntaxHighlightRangeService {
  public static func plan(
    accumulating previousPlan: MarkdownSyntaxHighlightPlan?,
    previousText: String,
    currentText: String,
    replacedRange: NSRange,
    knownCodeBlockRanges: [NSRange]?
  ) -> MarkdownSyntaxHighlightPlan {
    let previous = previousText as NSString
    let current = currentText as NSString
    guard let currentChangeRange = currentChangeRange(
      previousLength: previous.length,
      currentLength: current.length,
      replacedRange: replacedRange
    ) else {
      return .fullDocument(for: currentText)
    }

    guard !touchesCodeFence(replacedRange, in: previous),
          !touchesCodeFence(currentChangeRange, in: current) else {
      return .fullDocument(for: currentText)
    }

    guard let knownCodeBlockRanges else {
      return .fullDocument(for: currentText)
    }

    let updatedCodeBlockRanges = transformedCodeBlockRanges(
      knownCodeBlockRanges,
      replacedRange: replacedRange,
      currentChangeRange: currentChangeRange,
      currentLength: current.length
    )

    let accumulatedRange = accumulatedRange(
      previousPlan?.range,
      replacedRange: replacedRange,
      currentChangeRange: currentChangeRange,
      currentLength: current.length
    )
    var expandedRange = current.lineRange(for: accumulatedRange)
    for codeBlockRange in updatedCodeBlockRanges {
      if NSIntersectionRange(expandedRange, codeBlockRange).length > 0 {
        expandedRange = NSUnionRange(expandedRange, codeBlockRange)
      }
    }
    return MarkdownSyntaxHighlightPlan(
      range: expandedRange,
      codeBlockRanges: updatedCodeBlockRanges
    )
  }

  public static func resolvingCodeBlockRanges(
    in markdown: String,
    plan: MarkdownSyntaxHighlightPlan
  ) -> MarkdownSyntaxHighlightPlan {
    guard plan.codeBlockRanges == nil else { return plan }
    return MarkdownSyntaxHighlightPlan(
      range: plan.range,
      codeBlockRanges: codeBlockRanges(in: markdown as NSString)
    )
  }

  private static func currentChangeRange(
    previousLength: Int,
    currentLength: Int,
    replacedRange: NSRange
  ) -> NSRange? {
    guard replacedRange.location != NSNotFound,
          replacedRange.location >= 0,
          replacedRange.length >= 0,
          replacedRange.location <= previousLength,
          replacedRange.length <= previousLength - replacedRange.location else {
      return nil
    }
    let retainedLength = previousLength - replacedRange.length
    let insertedLength = currentLength - retainedLength
    guard insertedLength >= 0,
          replacedRange.location <= currentLength,
          insertedLength <= currentLength - replacedRange.location else {
      return nil
    }
    return NSRange(location: replacedRange.location, length: insertedLength)
  }

  private static func accumulatedRange(
    _ previousDirtyRange: NSRange?,
    replacedRange: NSRange,
    currentChangeRange: NSRange,
    currentLength: Int
  ) -> NSRange {
    guard let previousDirtyRange,
          previousDirtyRange.location != NSNotFound,
          previousDirtyRange.location >= 0,
          previousDirtyRange.length >= 0 else {
      return currentChangeRange
    }

    let editStart = replacedRange.location
    let editEnd = NSMaxRange(replacedRange)
    let insertedEnd = NSMaxRange(currentChangeRange)
    let delta = currentChangeRange.length - replacedRange.length
    let previousDirtyEnd = NSMaxRange(previousDirtyRange)
    let transformedDirtyEnd: Int
    if previousDirtyEnd <= editStart {
      transformedDirtyEnd = previousDirtyEnd
    } else if previousDirtyEnd >= editEnd {
      transformedDirtyEnd = previousDirtyEnd + delta
    } else {
      transformedDirtyEnd = insertedEnd
    }

    let start = min(previousDirtyRange.location, currentChangeRange.location)
    let end = min(
      currentLength,
      max(start, transformedDirtyEnd, insertedEnd)
    )
    return NSRange(location: min(start, currentLength), length: max(0, end - start))
  }

  private static func transformedCodeBlockRanges(
    _ ranges: [NSRange],
    replacedRange: NSRange,
    currentChangeRange: NSRange,
    currentLength: Int
  ) -> [NSRange] {
    let editStart = replacedRange.location
    let editEnd = NSMaxRange(replacedRange)
    let insertedEnd = NSMaxRange(currentChangeRange)
    let delta = currentChangeRange.length - replacedRange.length

    return ranges.compactMap { range in
      let previousStart = range.location
      let previousEnd = NSMaxRange(range)
      let transformedStart: Int
      let transformedEnd: Int

      if previousEnd <= editStart {
        transformedStart = previousStart
        transformedEnd = previousEnd
      } else if previousStart >= editEnd {
        transformedStart = previousStart + delta
        transformedEnd = previousEnd + delta
      } else {
        transformedStart = previousStart < editStart ? previousStart : editStart
        transformedEnd = previousEnd >= editEnd ? previousEnd + delta : insertedEnd
      }

      let clampedStart = min(max(0, transformedStart), currentLength)
      let clampedEnd = min(max(clampedStart, transformedEnd), currentLength)
      guard clampedEnd > clampedStart else { return nil }
      return NSRange(location: clampedStart, length: clampedEnd - clampedStart)
    }
  }

  private static func touchesCodeFence(_ range: NSRange, in text: NSString) -> Bool {
    guard range.location != NSNotFound,
          range.location >= 0,
          range.length >= 0,
          range.location <= text.length,
          range.length <= text.length - range.location else {
      return true
    }
    let changedLines = text.substring(with: text.lineRange(for: range))
    return changedLines.contains("`") || changedLines.contains("~~~")
  }

  private static func codeBlockRanges(in text: NSString) -> [NSRange] {
    MarkdownCodeRangeScanner.scan(text as String).blockRanges
  }
}
