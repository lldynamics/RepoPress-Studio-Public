import Foundation

public enum MarkdownSyntaxHighlightApplicationPlanner {
  public static let defaultMaximumChunkUTF16Length = 8_192

  public static func chunks(
    in range: NSRange,
    prioritizing priorityRange: NSRange?,
    maximumChunkUTF16Length: Int = defaultMaximumChunkUTF16Length
  ) -> [NSRange] {
    guard isValid(range),
          range.length > 0,
          maximumChunkUTF16Length > 0 else {
      return []
    }

    guard let priorityRange,
          isValid(priorityRange) else {
      return forwardChunks(in: range, maximumLength: maximumChunkUTF16Length)
    }
    let prioritizedRange = NSIntersectionRange(range, priorityRange)
    guard prioritizedRange.length > 0 else {
      return forwardChunks(in: range, maximumLength: maximumChunkUTF16Length)
    }

    let leadingRange = NSRange(
      location: range.location,
      length: prioritizedRange.location - range.location
    )
    let trailingRange = NSRange(
      location: NSMaxRange(prioritizedRange),
      length: NSMaxRange(range) - NSMaxRange(prioritizedRange)
    )
    return forwardChunks(
      in: prioritizedRange,
      maximumLength: maximumChunkUTF16Length
    ) + backwardChunks(
      in: leadingRange,
      maximumLength: maximumChunkUTF16Length
    ) + forwardChunks(
      in: trailingRange,
      maximumLength: maximumChunkUTF16Length
    )
  }

  public static func applicationSnapshots(
    for snapshot: MarkdownSyntaxHighlightSnapshot,
    prioritizing priorityRange: NSRange?,
    maximumChunkUTF16Length: Int = defaultMaximumChunkUTF16Length
  ) -> [MarkdownSyntaxHighlightSnapshot] {
    guard isValid(snapshot.range) else { return [] }
    guard snapshot.range.length > 0 else { return [snapshot] }
    let applicationRanges = chunks(
      in: snapshot.range,
      prioritizing: priorityRange,
      maximumChunkUTF16Length: maximumChunkUTF16Length
    )
    guard !applicationRanges.isEmpty else { return [] }

    return applicationRanges.map { applicationRange in
      let runs = snapshot.runs.compactMap { run -> MarkdownSyntaxHighlightRun? in
        guard isContained(run.range, in: snapshot.range) else { return nil }
        let intersection = NSIntersectionRange(run.range, applicationRange)
        guard intersection.length > 0 else { return nil }
        return MarkdownSyntaxHighlightRun(style: run.style, range: intersection)
      }
      return MarkdownSyntaxHighlightSnapshot(range: applicationRange, runs: runs)
    }
  }

  public static func prioritizing(
    _ snapshots: [MarkdownSyntaxHighlightSnapshot],
    around priorityRange: NSRange?
  ) -> [MarkdownSyntaxHighlightSnapshot] {
    guard let priorityRange,
          isValid(priorityRange) else {
      return snapshots
    }
    var prioritized: [MarkdownSyntaxHighlightSnapshot] = []
    var remaining: [MarkdownSyntaxHighlightSnapshot] = []
    for snapshot in snapshots {
      if isValid(snapshot.range),
         NSIntersectionRange(snapshot.range, priorityRange).length > 0 {
        prioritized.append(snapshot)
      } else {
        remaining.append(snapshot)
      }
    }
    guard !prioritized.isEmpty else { return snapshots }
    return prioritized + remaining
  }

  private static func forwardChunks(
    in range: NSRange,
    maximumLength: Int
  ) -> [NSRange] {
    guard range.length > 0 else { return [] }
    var chunks: [NSRange] = []
    var location = range.location
    let end = NSMaxRange(range)
    while location < end {
      let length = min(maximumLength, end - location)
      chunks.append(NSRange(location: location, length: length))
      location += length
    }
    return chunks
  }

  private static func backwardChunks(
    in range: NSRange,
    maximumLength: Int
  ) -> [NSRange] {
    guard range.length > 0 else { return [] }
    var chunks: [NSRange] = []
    var end = NSMaxRange(range)
    while end > range.location {
      let length = min(maximumLength, end - range.location)
      let location = end - length
      chunks.append(NSRange(location: location, length: length))
      end = location
    }
    return chunks
  }

  private static func isValid(_ range: NSRange) -> Bool {
    range.location != NSNotFound
      && range.location >= 0
      && range.length >= 0
      && range.location <= Int.max - range.length
  }

  private static func isContained(_ range: NSRange, in enclosingRange: NSRange) -> Bool {
    isValid(range)
      && range.location >= enclosingRange.location
      && NSMaxRange(range) <= NSMaxRange(enclosingRange)
  }
}

public enum MarkdownSyntaxHighlightAttributeApplier {
  @discardableResult
  public static func apply(
    _ snapshot: MarkdownSyntaxHighlightSnapshot,
    to textStorage: NSMutableAttributedString,
    defaultAttributes: [NSAttributedString.Key: Any],
    styleAttributes: [MarkdownSyntaxHighlightStyle: [NSAttributedString.Key: Any]]
  ) -> Int {
    apply(
      snapshot,
      to: textStorage,
      within: snapshot.range,
      defaultAttributes: defaultAttributes,
      styleAttributes: styleAttributes
    )
  }

  @discardableResult
  public static func apply(
    _ snapshot: MarkdownSyntaxHighlightSnapshot,
    to textStorage: NSMutableAttributedString,
    within applicationRange: NSRange,
    defaultAttributes: [NSAttributedString.Key: Any],
    styleAttributes: [MarkdownSyntaxHighlightStyle: [NSAttributedString.Key: Any]]
  ) -> Int {
    guard isValid(snapshot.range, length: textStorage.length) else { return 0 }
    guard isValid(
      applicationRange,
      within: snapshot.range,
      storageLength: textStorage.length
    ) else {
      return 0
    }

    textStorage.setAttributes(defaultAttributes, range: applicationRange)
    var appliedRunCount = 0
    for run in snapshot.runs {
      guard let attributes = styleAttributes[run.style],
            isValid(run.range, within: snapshot.range, storageLength: textStorage.length) else {
        continue
      }
      let intersection = NSIntersectionRange(run.range, applicationRange)
      guard intersection.length > 0 else { continue }
      textStorage.addAttributes(attributes, range: intersection)
      appliedRunCount += 1
    }
    return appliedRunCount
  }

  private static func isValid(_ range: NSRange, length: Int) -> Bool {
    range.location != NSNotFound
      && range.location >= 0
      && range.length >= 0
      && range.location <= length
      && range.length <= length - range.location
  }

  private static func isValid(
    _ range: NSRange,
    within enclosingRange: NSRange,
    storageLength: Int
  ) -> Bool {
    isValid(range, length: storageLength)
      && range.location >= enclosingRange.location
      && range.length <= NSMaxRange(enclosingRange) - range.location
  }
}
