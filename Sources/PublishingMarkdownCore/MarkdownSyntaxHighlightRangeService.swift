import Foundation

public struct MarkdownSyntaxHighlightPlan: Hashable, Sendable {
  public var range: NSRange
  public var codeBlockRanges: [NSRange]?
  /// A line-aligned window whose fenced-code state must be rebuilt before parsing.
  /// `codeBlockRanges` contains only stable ranges outside this window until
  /// `resolvingCodeBlockRanges` completes the resynchronization.
  var codeBlockRescanRange: NSRange?

  public init(range: NSRange, codeBlockRanges: [NSRange]? = nil) {
    self.range = range
    self.codeBlockRanges = codeBlockRanges
    codeBlockRescanRange = nil
  }

  init(
    range: NSRange,
    codeBlockRanges: [NSRange]?,
    codeBlockRescanRange: NSRange
  ) {
    self.range = range
    self.codeBlockRanges = codeBlockRanges
    self.codeBlockRescanRange = codeBlockRescanRange
  }

  public static func fullDocument(for markdown: String) -> Self {
    MarkdownSyntaxHighlightPlan(
      range: NSRange(location: 0, length: (markdown as NSString).length)
    )
  }

  public var requiresCodeBlockResynchronization: Bool {
    codeBlockRescanRange != nil
  }
}

public enum MarkdownSyntaxHighlightSchedulingPolicy {
  public static let localEditDelay: TimeInterval = 0.045
  public static let expensiveEditDelay: TimeInterval = 0.12
  public static let idleTreeSynchronizationDelay: TimeInterval = 0.18
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
          plan.codeBlockRanges != nil,
          plan.codeBlockRescanRange == nil else {
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
  public static let defaultViewportContextLineCount = 50

  public static func paddedLineRange(
    in markdown: String,
    visibleRange: NSRange,
    contextLineCount: Int = defaultViewportContextLineCount
  ) -> NSRange {
    let source = markdown as NSString
    guard source.length > 0,
          visibleRange.location != NSNotFound,
          visibleRange.location >= 0,
          visibleRange.length >= 0,
          visibleRange.location <= source.length,
          visibleRange.length <= source.length - visibleRange.location else {
      return NSRange(location: 0, length: 0)
    }

    let safeContextLineCount = max(0, contextLineCount)
    var paddedRange = source.lineRange(for: visibleRange)
    for _ in 0..<safeContextLineCount where paddedRange.location > 0 {
      let previousLineRange = source.lineRange(
        for: NSRange(location: paddedRange.location - 1, length: 0)
      )
      paddedRange = NSUnionRange(previousLineRange, paddedRange)
    }
    for _ in 0..<safeContextLineCount where NSMaxRange(paddedRange) < source.length {
      let nextLineRange = source.lineRange(
        for: NSRange(location: NSMaxRange(paddedRange), length: 0)
      )
      paddedRange = NSUnionRange(paddedRange, nextLineRange)
    }
    return paddedRange
  }

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

    guard let knownCodeBlockRanges else {
      return .fullDocument(for: currentText)
    }

    let updatedCodeBlockRanges = transformedCodeBlockRanges(
      knownCodeBlockRanges,
      replacedRange: replacedRange,
      currentChangeRange: currentChangeRange,
      currentLength: current.length
    )

    let transformedPreviousRescanRange = previousPlan?.codeBlockRescanRange.flatMap {
      transformedCodeBlockRanges(
        [$0],
        replacedRange: replacedRange,
        currentChangeRange: currentChangeRange,
        currentLength: current.length
      ).first
    }
    let fenceStructureDidChange = fenceStructureChanged(
      previous: previous,
      current: current,
      replacedRange: replacedRange,
      currentChangeRange: currentChangeRange,
      knownCodeBlockRanges: knownCodeBlockRanges
    )
    if fenceStructureDidChange || transformedPreviousRescanRange != nil {
      var rescanRange = transformedPreviousRescanRange
      if fenceStructureDidChange {
        let anchors = codeBlockResynchronizationAnchors(
          previous: previous,
          current: current,
          replacedRange: replacedRange,
          currentChangeRange: currentChangeRange,
          knownCodeBlockRanges: knownCodeBlockRanges,
          updatedCodeBlockRanges: updatedCodeBlockRanges
        )
        if let pendingRange = transformedPreviousRescanRange {
          // A pending window produced by fenceResynchronizationWindow has an
          // outside-state boundary when it ends before EOF. If a subsequent
          // structural edit is strictly after that boundary, the unresolved
          // window and the new convergence window can be scanned as one
          // contiguous region. This preserves the state transition through
          // the gap without invalidating the known suffix.
          let pendingEnd = NSMaxRange(pendingRange)
          if pendingEnd < current.length,
             currentChangeRange.location >= pendingEnd {
            let convergenceWindow = MarkdownCodeRangeScanner.fenceResynchronizationWindow(
              previous: previous,
              current: current,
              previousAnchor: anchors.previous,
              currentAnchor: anchors.current,
              replacedRange: replacedRange,
              currentChangeRange: currentChangeRange
            )
            let combinedRange = NSUnionRange(
              pendingRange,
              convergenceWindow.currentRange
            )
            let combinedEnd = NSMaxRange(combinedRange)
            return MarkdownSyntaxHighlightPlan(
              range: combinedRange,
              codeBlockRanges: updatedCodeBlockRanges.filter {
                NSMaxRange($0) <= combinedRange.location || $0.location >= combinedEnd
              },
              codeBlockRescanRange: combinedRange
            )
          }

          // The stable cache no longer describes an overlapping or preceding
          // unresolved window. There is no safe splice point, so keep the
          // earliest outside-state anchor and rebuild through EOF.
          let rescanStart = min(pendingRange.location, anchors.current)
          let conservativeRange = NSRange(
            location: rescanStart,
            length: current.length - rescanStart
          )
          return MarkdownSyntaxHighlightPlan(
            range: conservativeRange,
            codeBlockRanges: updatedCodeBlockRanges.filter {
              NSMaxRange($0) <= rescanStart
            },
            codeBlockRescanRange: conservativeRange
          )
        }
        let convergenceWindow = MarkdownCodeRangeScanner.fenceResynchronizationWindow(
          previous: previous,
          current: current,
          previousAnchor: anchors.previous,
          currentAnchor: anchors.current,
          replacedRange: replacedRange,
          currentChangeRange: currentChangeRange
        )
        rescanRange = rescanRange.map {
          NSUnionRange($0, convergenceWindow.currentRange)
        } ?? convergenceWindow.currentRange
      } else {
        let accumulated = accumulatedRange(
          previousPlan?.range,
          replacedRange: replacedRange,
          currentChangeRange: currentChangeRange,
          currentLength: current.length
        )
        var expanded = current.lineRange(for: accumulated)
        for codeBlockRange in updatedCodeBlockRanges
        where NSIntersectionRange(expanded, codeBlockRange).length > 0 {
          expanded = NSUnionRange(expanded, codeBlockRange)
        }
        rescanRange = rescanRange.map { NSUnionRange($0, expanded) } ?? expanded
      }
      guard let rescanRange else {
        return .fullDocument(for: currentText)
      }
      let rescanEnd = NSMaxRange(rescanRange)
      return MarkdownSyntaxHighlightPlan(
        range: rescanRange,
        codeBlockRanges: updatedCodeBlockRanges.filter {
          NSMaxRange($0) <= rescanRange.location || $0.location >= rescanEnd
        },
        codeBlockRescanRange: rescanRange
      )
    }

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
    if let rescanRange = plan.codeBlockRescanRange {
      let source = markdown as NSString
      guard isValid(rescanRange, length: source.length) else {
        return MarkdownSyntaxHighlightPlan(
          range: NSRange(location: 0, length: source.length),
          codeBlockRanges: codeBlockRanges(in: source)
        )
      }
      let rescanEnd = NSMaxRange(rescanRange)
      let stableRanges = (plan.codeBlockRanges ?? []).filter {
        NSMaxRange($0) <= rescanRange.location || $0.location >= rescanEnd
      }
      let rescannedWindow = MarkdownCodeRangeScanner.scan(
        source,
        in: rescanRange
      ).blockRanges
      return MarkdownSyntaxHighlightPlan(
        range: plan.range,
        codeBlockRanges: (stableRanges + rescannedWindow).sorted {
          $0.location < $1.location
        }
      )
    }
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

  private struct FenceLineSignature: Equatable {
    var marker: unichar
    var length: Int
    var lineRange: NSRange
    var markerRange: NSRange
    var contentsEnd: Int
  }

  private static func fenceStructureChanged(
    previous: NSString,
    current: NSString,
    replacedRange: NSRange,
    currentChangeRange: NSRange,
    knownCodeBlockRanges: [NSRange]
  ) -> Bool {
    let previousFences = fenceLineSignatures(in: previous, around: replacedRange)
    let currentFences = fenceLineSignatures(in: current, around: currentChangeRange)
    guard !previousFences.isEmpty || !currentFences.isEmpty else { return false }
    return !isNonStructuralOpeningFenceInfoEdit(
      previous: previous,
      current: current,
      replacedRange: replacedRange,
      currentChangeRange: currentChangeRange,
      previousFences: previousFences,
      currentFences: currentFences,
      knownCodeBlockRanges: knownCodeBlockRanges
    )
  }

  private static func isNonStructuralOpeningFenceInfoEdit(
    previous: NSString,
    current: NSString,
    replacedRange: NSRange,
    currentChangeRange: NSRange,
    previousFences: [FenceLineSignature],
    currentFences: [FenceLineSignature],
    knownCodeBlockRanges: [NSRange]
  ) -> Bool {
    guard previousFences.count == 1,
          currentFences.count == 1 else { return false }
    let oldFence = previousFences[0]
    let newFence = currentFences[0]
    guard oldFence.marker == newFence.marker,
          oldFence.length == newFence.length,
          knownCodeBlockRanges.contains(where: {
            $0.location == oldFence.lineRange.location
              && NSMaxRange($0) >= oldFence.contentsEnd
          }),
          replacedRange.location >= NSMaxRange(oldFence.markerRange),
          NSMaxRange(replacedRange) <= oldFence.contentsEnd,
          currentChangeRange.location >= NSMaxRange(newFence.markerRange),
          NSMaxRange(currentChangeRange) <= newFence.contentsEnd,
          !containsLineBreak(previous, range: replacedRange),
          !containsLineBreak(current, range: currentChangeRange) else {
      return false
    }
    return true
  }

  private static func fenceLineSignatures(
    in source: NSString,
    around range: NSRange
  ) -> [FenceLineSignature] {
    guard isValid(range, length: source.length) else { return [] }
    let lines = source.lineRange(for: range)
    let upperBound = NSMaxRange(lines)
    var location = lines.location
    var signatures: [FenceLineSignature] = []
    while location < upperBound {
      var lineStart = 0
      var lineEnd = 0
      var contentsEnd = 0
      source.getLineStart(
        &lineStart,
        end: &lineEnd,
        contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0)
      )
      if let signature = fenceLineSignature(
        in: source,
        lineRange: NSRange(
          location: lineStart,
          length: max(0, contentsEnd - lineStart)
        )
      ) {
        signatures.append(signature)
      }
      location = max(lineEnd, location + 1)
    }
    return signatures
  }

  private static func fenceLineSignature(
    in source: NSString,
    lineRange: NSRange
  ) -> FenceLineSignature? {
    var cursor = lineRange.location
    let end = NSMaxRange(lineRange)
    var spaces = 0
    while cursor < end, source.character(at: cursor) == 32, spaces < 4 {
      spaces += 1
      cursor += 1
    }
    guard spaces <= 3, cursor < end else { return nil }
    let marker = source.character(at: cursor)
    guard marker == 96 || marker == 126 else { return nil }
    let markerStart = cursor
    while cursor < end, source.character(at: cursor) == marker {
      cursor += 1
    }
    let length = cursor - markerStart
    guard length >= 3 else { return nil }
    if marker == 96 {
      var infoCursor = cursor
      while infoCursor < end {
        guard source.character(at: infoCursor) != 96 else { return nil }
        infoCursor += 1
      }
    }
    return FenceLineSignature(
      marker: marker,
      length: length,
      lineRange: lineRange,
      markerRange: NSRange(location: markerStart, length: length),
      contentsEnd: end
    )
  }

  private static func containsLineBreak(_ source: NSString, range: NSRange) -> Bool {
    guard range.length > 0 else { return false }
    for location in range.location..<NSMaxRange(range) {
      let character = source.character(at: location)
      if character == 10 || character == 13 { return true }
    }
    return false
  }

  private static func codeBlockResynchronizationAnchors(
    previous: NSString,
    current: NSString,
    replacedRange: NSRange,
    currentChangeRange: NSRange,
    knownCodeBlockRanges: [NSRange],
    updatedCodeBlockRanges: [NSRange]
  ) -> (previous: Int, current: Int) {
    let previousLineRange = previous.lineRange(for: replacedRange)
    let currentLineRange = current.lineRange(for: currentChangeRange)
    var previousStart = previousLineRange.location
    var currentStart = currentLineRange.location
    for range in knownCodeBlockRanges where rangesTouch(range, previousLineRange) {
      previousStart = min(previousStart, min(range.location, previous.length))
    }
    for range in updatedCodeBlockRanges where rangesTouch(range, currentLineRange) {
      currentStart = min(currentStart, range.location)
    }
    return (
      previous: previous.lineRange(
        for: NSRange(location: min(max(0, previousStart), previous.length), length: 0)
      ).location,
      current: current.lineRange(
        for: NSRange(location: min(max(0, currentStart), current.length), length: 0)
      ).location
    )
  }

  private static func rangesTouch(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
    lhs.location <= NSMaxRange(rhs) && rhs.location <= NSMaxRange(lhs)
  }

  private static func isValid(_ range: NSRange, length: Int) -> Bool {
    range.location != NSNotFound
      && range.location >= 0
      && range.length >= 0
      && range.location <= length
      && range.length <= length - range.location
  }

  private static func codeBlockRanges(in text: NSString) -> [NSRange] {
    MarkdownCodeRangeScanner.scan(text).blockRanges
  }
}
