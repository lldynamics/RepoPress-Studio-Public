import Foundation

public struct DraftVersionTextSegment: Hashable, Sendable {
  public var text: String
  public var isChanged: Bool

  public init(text: String, isChanged: Bool) {
    self.text = text
    self.isChanged = isChanged
  }
}

public struct DraftVersionAlignedLine: Hashable, Sendable {
  public var text: String
  public var lineNumber: Int
  public var kind: DraftVersionLineDiffKind
  public var segments: [DraftVersionTextSegment]

  public init(
    text: String,
    lineNumber: Int,
    kind: DraftVersionLineDiffKind,
    segments: [DraftVersionTextSegment]
  ) {
    self.text = text
    self.lineNumber = lineNumber
    self.kind = kind
    self.segments = segments
  }
}

public struct DraftVersionAlignedRow: Identifiable, Hashable, Sendable {
  public var id: Int
  public var previous: DraftVersionAlignedLine?
  public var current: DraftVersionAlignedLine?

  public init(
    id: Int,
    previous: DraftVersionAlignedLine?,
    current: DraftVersionAlignedLine?
  ) {
    self.id = id
    self.previous = previous
    self.current = current
  }

  public var hasChanges: Bool {
    previous?.kind == .removed || current?.kind == .added
  }
}

/// A presentation projection of the complete line diff. It does not create or
/// change snapshots, and does not use the context-collapsed diff as its input.
enum DraftVersionAlignedDiff {
  private static let maximumLineAlignmentCells = 16_384
  private static let maximumInlineAlignmentCells = 65_536
  private static let maximumInlineSegmentCount = 128
  private static let fingerprintCharacterLimit = 192

  static func rows(
    from lines: [DraftVersionLineDiff],
    previousBody: String? = nil,
    currentBody: String? = nil
  ) -> [DraftVersionAlignedRow] {
    let previousLines = previousBody?.components(separatedBy: "\n")
    let currentLines = currentBody?.components(separatedBy: "\n")
    var rows: [DraftVersionAlignedRow] = []
    var index = lines.startIndex

    while index < lines.endIndex {
      let line = lines[index]
      if line.kind == .unchanged {
        rows.append(
          DraftVersionAlignedRow(
            id: rows.count,
            previous: alignedLine(line, previous: true, originalLines: previousLines),
            current: alignedLine(line, previous: false, originalLines: currentLines)
          ))
        index += 1
        continue
      }

      var removed: [DraftVersionLineDiff] = []
      var added: [DraftVersionLineDiff] = []
      while index < lines.endIndex, lines[index].kind != .unchanged {
        switch lines[index].kind {
        case .removed: removed.append(lines[index])
        case .added: added.append(lines[index])
        case .unchanged, .skipped: break
        }
        index += 1
      }

      for pair in alignedPairs(previous: removed, current: added) {
        var previous = pair.previous.map {
          alignedLine($0, previous: true, originalLines: previousLines)
        }
        var current = pair.current.map {
          alignedLine($0, previous: false, originalLines: currentLines)
        }
        if let previousText = previous?.text, let currentText = current?.text {
          let segments = inlineSegments(previous: previousText, current: currentText)
          previous?.segments = segments.previous
          current?.segments = segments.current
        }
        rows.append(
          DraftVersionAlignedRow(
            id: rows.count,
            previous: previous,
            current: current
          ))
      }
    }
    return rows
  }

  private static func alignedLine(
    _ line: DraftVersionLineDiff,
    previous: Bool,
    originalLines: [String]?
  ) -> DraftVersionAlignedLine {
    let lineNumber = (previous ? line.previousLineNumber : line.currentLineNumber) ?? 0
    let text: String
    if let originalLines, originalLines.indices.contains(lineNumber - 1) {
      // String equality is canonically equivalent; preserve each side's exact
      // spelling even when CollectionDifference regards both lines as equal.
      text = originalLines[lineNumber - 1]
    } else {
      text = line.text
    }
    return DraftVersionAlignedLine(
      text: text,
      lineNumber: lineNumber,
      kind: line.kind,
      segments: [DraftVersionTextSegment(text: text, isChanged: line.kind != .unchanged)]
    )
  }

  private struct LinePair {
    var previous: DraftVersionLineDiff?
    var current: DraftVersionLineDiff?
  }

  private static func alignedPairs(
    previous: [DraftVersionLineDiff],
    current: [DraftVersionLineDiff]
  ) -> [LinePair] {
    guard !previous.isEmpty else { return current.map { LinePair(current: $0) } }
    guard !current.isEmpty else { return previous.map { LinePair(previous: $0) } }

    // Both dimensions are bounded before allocating or multiplying. For an
    // unusually large rewritten block, position pairing still preserves every
    // line and its order, without quadratic comparison work.
    guard previous.count < maximumLineAlignmentCells,
      current.count < maximumLineAlignmentCells,
      (previous.count + 1) * (current.count + 1) <= maximumLineAlignmentCells
    else {
      return (0..<max(previous.count, current.count)).map { index in
        LinePair(
          previous: index < previous.count ? previous[index] : nil,
          current: index < current.count ? current[index] : nil
        )
      }
    }

    let previousFingerprints = previous.map { LineFingerprint($0.text) }
    let currentFingerprints = current.map { LineFingerprint($0.text) }
    let width = current.count + 1
    var costs = [Double](repeating: 0, count: (previous.count + 1) * width)
    var steps = [UInt8](repeating: 0, count: costs.count)

    for previousIndex in stride(from: previous.count, through: 0, by: -1) {
      for currentIndex in stride(from: current.count, through: 0, by: -1) {
        let cell = previousIndex * width + currentIndex
        if previousIndex == previous.count, currentIndex == current.count { continue }
        if previousIndex == previous.count {
          costs[cell] = Double(current.count - currentIndex)
          steps[cell] = 2
        } else if currentIndex == current.count {
          costs[cell] = Double(previous.count - previousIndex)
          steps[cell] = 1
        } else {
          let similarity = previousFingerprints[previousIndex].similarity(
            to: currentFingerprints[currentIndex])
          let paired = costs[cell + width + 1] + 1.5 * (1 - similarity)
          let removed = costs[cell + width] + 1
          let added = costs[cell + 1] + 1
          if paired <= removed, paired <= added {
            costs[cell] = paired
          } else if removed <= added {
            costs[cell] = removed
            steps[cell] = 1
          } else {
            costs[cell] = added
            steps[cell] = 2
          }
        }
      }
    }

    var pairs: [LinePair] = []
    var previousIndex = 0
    var currentIndex = 0
    while previousIndex < previous.count || currentIndex < current.count {
      switch steps[previousIndex * width + currentIndex] {
      case 1:
        pairs.append(LinePair(previous: previous[previousIndex]))
        previousIndex += 1
      case 2:
        pairs.append(LinePair(current: current[currentIndex]))
        currentIndex += 1
      default:
        pairs.append(LinePair(previous: previous[previousIndex], current: current[currentIndex]))
        previousIndex += 1
        currentIndex += 1
      }
    }
    return pairs
  }

  /// Bounded grapheme-bigram fingerprints favor pairing related paragraphs
  /// instead of pairing an inserted paragraph with the next rewritten one.
  private struct LineFingerprint {
    var characterCount: Int
    var bigrams: [String: Int]
    var bigramCount: Int

    init(_ text: String) {
      characterCount = text.count
      let characters: [Character]
      if characterCount <= fingerprintCharacterLimit {
        characters = Array(text)
      } else {
        characters =
          Array(text.prefix(fingerprintCharacterLimit / 2))
          + Array(text.suffix(fingerprintCharacterLimit / 2))
      }
      var bigrams: [String: Int] = [:]
      if characters.count < 2 {
        if let character = characters.first { bigrams[String(character)] = 1 }
      } else {
        for index in 1..<characters.count {
          bigrams[String(characters[index - 1]) + String(characters[index]), default: 0] += 1
        }
      }
      self.bigrams = bigrams
      bigramCount = bigrams.values.reduce(0, +)
    }

    func similarity(to other: Self) -> Double {
      if characterCount == 0 || other.characterCount == 0 {
        return characterCount == other.characterCount ? 1 : 0
      }
      let common = bigrams.reduce(0) { result, entry in
        result + min(entry.value, other.bigrams[entry.key, default: 0])
      }
      let overlap = Double(2 * common) / Double(max(1, bigramCount + other.bigramCount))
      let lengthRatio =
        Double(min(characterCount, other.characterCount))
        / Double(max(characterCount, other.characterCount))
      return overlap * (0.65 + 0.35 * lengthRatio)
    }
  }

  private static func inlineSegments(
    previous: String,
    current: String
  ) -> (previous: [DraftVersionTextSegment], current: [DraftVersionTextSegment]) {
    if previous == current {
      return (
        [DraftVersionTextSegment(text: previous, isChanged: false)],
        [DraftVersionTextSegment(text: current, isChanged: false)]
      )
    }

    // Character arrays retain extended grapheme clusters (CJK, combining
    // accents, emoji and joined emoji). Prefix/suffix trimming is linear and
    // also gives useful highlights when the bounded LCS falls back.
    let previousCharacters = Array(previous)
    let currentCharacters = Array(current)
    var prefixCount = 0
    while prefixCount < min(previousCharacters.count, currentCharacters.count),
      previousCharacters[prefixCount] == currentCharacters[prefixCount]
    {
      prefixCount += 1
    }
    var suffixCount = 0
    while suffixCount < min(previousCharacters.count, currentCharacters.count) - prefixCount,
      previousCharacters[previousCharacters.count - suffixCount - 1]
        == currentCharacters[currentCharacters.count - suffixCount - 1]
    {
      suffixCount += 1
    }
    let previousMiddle = Array(
      previousCharacters[prefixCount..<(previousCharacters.count - suffixCount)])
    let currentMiddle = Array(
      currentCharacters[prefixCount..<(currentCharacters.count - suffixCount)])
    var previousSegments: [DraftVersionTextSegment] = []
    var currentSegments: [DraftVersionTextSegment] = []
    let previousPrefix = String(previousCharacters.prefix(prefixCount))
    let currentPrefix = String(currentCharacters.prefix(prefixCount))
    append(previousPrefix, changed: false, to: &previousSegments)
    append(currentPrefix, changed: false, to: &currentSegments)

    if previousMiddle.isEmpty || currentMiddle.isEmpty {
      append(String(previousMiddle), changed: true, to: &previousSegments)
      append(String(currentMiddle), changed: true, to: &currentSegments)
    } else if previousMiddle.count < maximumInlineAlignmentCells,
      currentMiddle.count < maximumInlineAlignmentCells,
      (previousMiddle.count + 1) * (currentMiddle.count + 1) <= maximumInlineAlignmentCells
    {
      appendInlineLCS(
        previous: previousMiddle,
        current: currentMiddle,
        previousSegments: &previousSegments,
        currentSegments: &currentSegments
      )
      // A dense alternating edit should not create hundreds of individual
      // SwiftUI text runs. Reserve room for the suffix before rendering.
      if previousSegments.count >= maximumInlineSegmentCount
        || currentSegments.count >= maximumInlineSegmentCount
      {
        previousSegments = []
        currentSegments = []
        append(previousPrefix, changed: false, to: &previousSegments)
        append(currentPrefix, changed: false, to: &currentSegments)
        append(String(previousMiddle), changed: true, to: &previousSegments)
        append(String(currentMiddle), changed: true, to: &currentSegments)
      }
    } else {
      append(String(previousMiddle), changed: true, to: &previousSegments)
      append(String(currentMiddle), changed: true, to: &currentSegments)
    }

    append(String(previousCharacters.suffix(suffixCount)), changed: false, to: &previousSegments)
    append(String(currentCharacters.suffix(suffixCount)), changed: false, to: &currentSegments)
    return (previousSegments, currentSegments)
  }

  private static func appendInlineLCS(
    previous: [Character],
    current: [Character],
    previousSegments: inout [DraftVersionTextSegment],
    currentSegments: inout [DraftVersionTextSegment]
  ) {
    let width = current.count + 1
    var lengths = [Int](repeating: 0, count: (previous.count + 1) * width)
    for previousIndex in stride(from: previous.count - 1, through: 0, by: -1) {
      for currentIndex in stride(from: current.count - 1, through: 0, by: -1) {
        let cell = previousIndex * width + currentIndex
        if previous[previousIndex] == current[currentIndex] {
          lengths[cell] = lengths[cell + width + 1] + 1
        } else {
          lengths[cell] = max(lengths[cell + width], lengths[cell + 1])
        }
      }
    }

    var previousIndex = 0
    var currentIndex = 0
    while previousIndex < previous.count || currentIndex < current.count {
      if previousIndex < previous.count, currentIndex < current.count,
        previous[previousIndex] == current[currentIndex]
      {
        append(String(previous[previousIndex]), changed: false, to: &previousSegments)
        append(String(current[currentIndex]), changed: false, to: &currentSegments)
        previousIndex += 1
        currentIndex += 1
      } else if previousIndex < previous.count,
        currentIndex == current.count
          || lengths[(previousIndex + 1) * width + currentIndex]
            >= lengths[previousIndex * width + currentIndex + 1]
      {
        append(String(previous[previousIndex]), changed: true, to: &previousSegments)
        previousIndex += 1
      } else {
        append(String(current[currentIndex]), changed: true, to: &currentSegments)
        currentIndex += 1
      }
    }
  }

  private static func append(
    _ text: String,
    changed: Bool,
    to segments: inout [DraftVersionTextSegment]
  ) {
    guard !text.isEmpty else { return }
    if segments.last?.isChanged == changed {
      segments[segments.count - 1].text += text
    } else {
      segments.append(DraftVersionTextSegment(text: text, isChanged: changed))
    }
  }
}
