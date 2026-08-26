import Foundation

/// The direction to use when a source offset falls inside a source range that
/// is represented by a single replacement character in the presentation
/// document.
public enum MarkdownTextPresentationAffinity: Hashable, Sendable {
  /// Resolve toward the beginning of a collapsed source range.
  case upstream

  /// Resolve toward the end of a collapsed source range.
  case downstream
}

/// An attachment range supplied by a Markdown parser to the presentation
/// projection. The `kind` is optional so the projection can also be used by
/// callers that only have source ranges at this stage.
public struct MarkdownTextPresentationAttachment: Hashable, Sendable {
  public var sourceRange: NSRange
  public var kind: MarkdownInlineAttachmentItem.Kind?

  public init(
    sourceRange: NSRange,
    kind: MarkdownInlineAttachmentItem.Kind? = nil
  ) {
    self.sourceRange = sourceRange
    self.kind = kind
  }

  public init(item: MarkdownInlineAttachmentItem) {
    self.init(sourceRange: item.range, kind: item.kind)
  }
}

/// A source range and its corresponding range in the derived TextKit
/// presentation string.
public struct MarkdownTextPresentationSegment: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case text
    case attachment(MarkdownTextPresentationAttachment)
  }

  public var sourceRange: NSRange
  public var presentationRange: NSRange
  public var kind: Kind

  public init(
    sourceRange: NSRange,
    presentationRange: NSRange,
    kind: Kind
  ) {
    self.sourceRange = sourceRange
    self.presentationRange = presentationRange
    self.kind = kind
  }

  public var isAttachment: Bool {
    if case .attachment = kind { return true }
    return false
  }

  public var attachment: MarkdownTextPresentationAttachment? {
    guard case .attachment(let attachment) = kind else { return nil }
    return attachment
  }
}

/// Why a supplied attachment was not included in a projection.
public enum MarkdownTextPresentationAttachmentRejectionReason: Hashable, Sendable {
  case negativeLocation
  case negativeLength
  case zeroLength
  case outOfBounds
  case overlapsAcceptedAttachment
}

public struct MarkdownTextPresentationRejectedAttachment: Hashable, Sendable {
  public var attachment: MarkdownTextPresentationAttachment
  public var reason: MarkdownTextPresentationAttachmentRejectionReason

  public init(
    attachment: MarkdownTextPresentationAttachment,
    reason: MarkdownTextPresentationAttachmentRejectionReason
  ) {
    self.attachment = attachment
    self.reason = reason
  }
}

/// A reversible projection from the Markdown source document into a TextKit
/// presentation document.
///
/// The source string remains the only editable/persisted representation. Each
/// accepted attachment range is represented by one U+FFFC in `presentation`.
/// Normalization sorts k supplied ranges, so complete construction is
/// O(n + k log k), where n is the source UTF-16 length. The mapping metadata
/// stores O(k) segments (in addition to the O(n) source/presentation strings),
/// and offset lookup uses binary search for O(log k) time.
public struct MarkdownTextPresentationProjection: Hashable, Sendable {
  public static let attachmentCharacter = "\u{FFFC}"

  public let source: String
  public let presentation: String
  public let segments: [MarkdownTextPresentationSegment]
  public let acceptedAttachments: [MarkdownTextPresentationAttachment]
  public let rejectedAttachments: [MarkdownTextPresentationRejectedAttachment]

  private let sourceLength: Int
  private let presentationLength: Int

  public init(
    source: String,
    attachments: [MarkdownTextPresentationAttachment] = []
  ) {
    self.source = source
    self.sourceLength = (source as NSString).length

    let normalized = Self.normalize(
      attachments,
      sourceLength: self.sourceLength
    )
    self.acceptedAttachments = normalized.accepted
    self.rejectedAttachments = normalized.rejected

    let sourceNSString = source as NSString
    var output = ""
    output.reserveCapacity(source.utf8.count)
    var builtSegments: [MarkdownTextPresentationSegment] = []
    builtSegments.reserveCapacity(normalized.accepted.count * 2 + 1)

    var sourceCursor = 0
    var presentationCursor = 0
    for attachment in normalized.accepted {
      let range = attachment.sourceRange
      if sourceCursor < range.location {
        let textRange = NSRange(
          location: sourceCursor,
          length: range.location - sourceCursor
        )
        let presentationRange = NSRange(
          location: presentationCursor,
          length: textRange.length
        )
        output.append(sourceNSString.substring(with: textRange))
        builtSegments.append(
          MarkdownTextPresentationSegment(
            sourceRange: textRange,
            presentationRange: presentationRange,
            kind: .text
          )
        )
        sourceCursor = range.location
        presentationCursor = NSMaxRange(presentationRange)
      }

      let presentationRange = NSRange(location: presentationCursor, length: 1)
      output.append(Self.attachmentCharacter)
      builtSegments.append(
        MarkdownTextPresentationSegment(
          sourceRange: range,
          presentationRange: presentationRange,
          kind: .attachment(attachment)
        )
      )
      sourceCursor = NSMaxRange(range)
      presentationCursor = NSMaxRange(presentationRange)
    }

    if sourceCursor < sourceLength {
      let textRange = NSRange(
        location: sourceCursor,
        length: sourceLength - sourceCursor
      )
      let presentationRange = NSRange(
        location: presentationCursor,
        length: textRange.length
      )
      output.append(sourceNSString.substring(with: textRange))
      builtSegments.append(
        MarkdownTextPresentationSegment(
          sourceRange: textRange,
          presentationRange: presentationRange,
          kind: .text
        )
      )
      presentationCursor = NSMaxRange(presentationRange)
    }

    self.presentation = output
    self.presentationLength = presentationCursor
    self.segments = builtSegments
  }

  /// Convenience initializer for the parser's existing attachment plan.
  public init(
    source: String,
    items: [MarkdownInlineAttachmentItem]
  ) {
    self.init(
      source: source,
      attachments: items.map(MarkdownTextPresentationAttachment.init(item:))
    )
  }

  /// The source UTF-16 length used by AppKit and TextKit.
  public var sourceUTF16Length: Int { sourceLength }

  /// The presentation UTF-16 length used by AppKit and TextKit.
  public var presentationUTF16Length: Int { presentationLength }

  /// Compatibility aliases that make the two document roles explicit at call
  /// sites that prefer `sourceText`/`presentationText` terminology.
  public var sourceText: String { source }
  public var presentationText: String { presentation }

  /// Convert a source UTF-16 offset into the presentation document.
  ///
  /// Offsets strictly inside an attachment use affinity; offsets at the
  /// source range's beginning/end resolve to the corresponding presentation
  /// boundary. Invalid offsets return `nil`.
  public func presentationOffset(
    forSourceOffset sourceOffset: Int,
    affinity: MarkdownTextPresentationAffinity = .downstream
  ) -> Int? {
    guard sourceOffset >= 0, sourceOffset <= sourceLength else { return nil }
    guard !segments.isEmpty else { return 0 }

    let firstAtOrAfter = lowerBoundSegmentStart(
      sourceOffset,
      usePresentationRange: false
    )

    if firstAtOrAfter < segments.count {
      let candidate = segments[firstAtOrAfter]
      if candidate.sourceRange.location == sourceOffset {
        return candidate.presentationRange.location
      }
    }

    if firstAtOrAfter > 0 {
      let previous = segments[firstAtOrAfter - 1]
      let previousEnd = NSMaxRange(previous.sourceRange)
      if sourceOffset < previousEnd {
        if previous.isAttachment {
          switch affinity {
          case .upstream:
            return previous.presentationRange.location
          case .downstream:
            return NSMaxRange(previous.presentationRange)
          }
        }
        return previous.presentationRange.location
          + (sourceOffset - previous.sourceRange.location)
      }
      if sourceOffset == previousEnd {
        return NSMaxRange(previous.presentationRange)
      }
    }

    // The only remaining valid position is the start of the next segment.
    if firstAtOrAfter < segments.count {
      return segments[firstAtOrAfter].presentationRange.location
    }
    return presentationLength
  }

  /// Convert a presentation UTF-16 offset into the Markdown source.
  ///
  /// At a replacement-character boundary, upstream resolves before the
  /// collapsed range and downstream resolves after it. This is intentionally
  /// a boundary mapping; use `sourceRange(forPresentationRange:)` when the
  /// replacement character itself is selected.
  public func sourceOffset(
    forPresentationOffset presentationOffset: Int,
    affinity: MarkdownTextPresentationAffinity = .downstream
  ) -> Int? {
    guard presentationOffset >= 0, presentationOffset <= presentationLength else {
      return nil
    }
    guard !segments.isEmpty else { return 0 }

    let firstAtOrAfter = lowerBoundSegmentStart(
      presentationOffset,
      usePresentationRange: true
    )

    if affinity == .downstream,
      firstAtOrAfter < segments.count,
      let attachment = segments[firstAtOrAfter].attachment,
      segments[firstAtOrAfter].presentationRange.location == presentationOffset
    {
      return NSMaxRange(attachment.sourceRange)
    }

    if affinity == .upstream, firstAtOrAfter > 0 {
      let previous = segments[firstAtOrAfter - 1]
      if previous.isAttachment,
        NSMaxRange(previous.presentationRange) == presentationOffset
      {
        return NSMaxRange(previous.sourceRange)
      }
    }

    if firstAtOrAfter < segments.count {
      let candidate = segments[firstAtOrAfter]
      if candidate.presentationRange.location == presentationOffset {
        return candidate.sourceRange.location
      }
    }

    if firstAtOrAfter > 0 {
      let previous = segments[firstAtOrAfter - 1]
      let previousEnd = NSMaxRange(previous.presentationRange)
      if presentationOffset < previousEnd {
        if previous.isAttachment {
          switch affinity {
          case .upstream:
            return previous.sourceRange.location
          case .downstream:
            return NSMaxRange(previous.sourceRange)
          }
        }
        return previous.sourceRange.location
          + (presentationOffset - previous.presentationRange.location)
      }
      if presentationOffset == previousEnd {
        return NSMaxRange(previous.sourceRange)
      }
    }

    if firstAtOrAfter < segments.count {
      return segments[firstAtOrAfter].sourceRange.location
    }
    return sourceLength
  }

  /// Convert a source range into its presentation range.
  ///
  /// A non-empty range that intersects an attachment includes the complete
  /// replacement character, even if the source range only partially covers
  /// the attachment syntax.
  public func presentationRange(
    forSourceRange sourceRange: NSRange,
    affinity: MarkdownTextPresentationAffinity = .downstream
  ) -> NSRange? {
    guard isValidBoundaryRange(sourceRange, upperBound: sourceLength) else {
      return nil
    }
    if sourceRange.length == 0 {
      guard let location = presentationOffset(
        forSourceOffset: sourceRange.location,
        affinity: affinity
      ) else { return nil }
      return NSRange(location: location, length: 0)
    }

    var lower: Int?
    var upper: Int?
    let sourceRangeEnd = NSMaxRange(sourceRange)
    var segmentIndex = firstSegmentIndexWhoseEndExceeds(
      sourceRange.location,
      usePresentationRange: false
    )
    while segmentIndex < segments.count {
      let segment = segments[segmentIndex]
      if segment.sourceRange.location >= sourceRangeEnd { break }
      let intersection = NSIntersectionRange(sourceRange, segment.sourceRange)
      if intersection.length == 0 {
        segmentIndex += 1
        continue
      }
      let presentationStart: Int
      let presentationEnd: Int
      if segment.isAttachment {
        presentationStart = segment.presentationRange.location
        presentationEnd = NSMaxRange(segment.presentationRange)
      } else {
        presentationStart = segment.presentationRange.location
          + (intersection.location - segment.sourceRange.location)
        presentationEnd = presentationStart + intersection.length
      }
      lower = min(lower ?? presentationStart, presentationStart)
      upper = max(upper ?? presentationEnd, presentationEnd)
      segmentIndex += 1
    }
    guard let lower, let upper else { return nil }
    return NSRange(location: lower, length: upper - lower)
  }

  /// Convert a presentation range into its source range.
  ///
  /// Selecting the U+FFFC replacement character maps back to the complete
  /// Markdown source range represented by that attachment.
  public func sourceRange(
    forPresentationRange presentationRange: NSRange,
    affinity: MarkdownTextPresentationAffinity = .downstream
  ) -> NSRange? {
    guard isValidBoundaryRange(presentationRange, upperBound: presentationLength) else {
      return nil
    }
    if presentationRange.length == 0 {
      guard let location = sourceOffset(
        forPresentationOffset: presentationRange.location,
        affinity: affinity
      ) else { return nil }
      return NSRange(location: location, length: 0)
    }

    var lower: Int?
    var upper: Int?
    let presentationRangeEnd = NSMaxRange(presentationRange)
    var segmentIndex = firstSegmentIndexWhoseEndExceeds(
      presentationRange.location,
      usePresentationRange: true
    )
    while segmentIndex < segments.count {
      let segment = segments[segmentIndex]
      if segment.presentationRange.location >= presentationRangeEnd { break }
      let intersection = NSIntersectionRange(presentationRange, segment.presentationRange)
      if intersection.length == 0 {
        segmentIndex += 1
        continue
      }
      let sourceStart: Int
      let sourceEnd: Int
      if let attachment = segment.attachment {
        sourceStart = attachment.sourceRange.location
        sourceEnd = NSMaxRange(attachment.sourceRange)
      } else {
        sourceStart = segment.sourceRange.location
          + (intersection.location - segment.presentationRange.location)
        sourceEnd = sourceStart + intersection.length
      }
      lower = min(lower ?? sourceStart, sourceStart)
      upper = max(upper ?? sourceEnd, sourceEnd)
      segmentIndex += 1
    }
    guard let lower, let upper else { return nil }
    return NSRange(location: lower, length: upper - lower)
  }

  /// Return the attachment segment containing a presentation character, if
  /// any. Replacement characters have a one-UTF-16-unit presentation range.
  public func attachment(
    atPresentationOffset presentationOffset: Int
  ) -> MarkdownTextPresentationAttachment? {
    guard presentationOffset >= 0, presentationOffset < presentationLength else {
      return nil
    }
    let firstAtOrAfter = lowerBoundSegmentStart(
      presentationOffset,
      usePresentationRange: true
    )
    if firstAtOrAfter < segments.count {
      let candidate = segments[firstAtOrAfter]
      if presentationOffset >= candidate.presentationRange.location,
        presentationOffset < NSMaxRange(candidate.presentationRange)
      {
        return candidate.attachment
      }
    }
    if firstAtOrAfter > 0 {
      let previous = segments[firstAtOrAfter - 1]
      if presentationOffset >= previous.presentationRange.location,
        presentationOffset < NSMaxRange(previous.presentationRange)
      {
        return previous.attachment
      }
    }
    return nil
  }

  private struct NormalizedAttachments {
    var accepted: [MarkdownTextPresentationAttachment]
    var rejected: [MarkdownTextPresentationRejectedAttachment]
  }

  private static func normalize(
    _ attachments: [MarkdownTextPresentationAttachment],
    sourceLength: Int
  ) -> NormalizedAttachments {
    let indexed = attachments.enumerated().sorted { lhs, rhs in
      let left = lhs.element
      let right = rhs.element
      if left.sourceRange.location != right.sourceRange.location {
        return left.sourceRange.location < right.sourceRange.location
      }
      if left.sourceRange.length != right.sourceRange.length {
        return left.sourceRange.length > right.sourceRange.length
      }
      let leftKey = canonicalKindKey(left.kind)
      let rightKey = canonicalKindKey(right.kind)
      if leftKey != rightKey { return leftKey < rightKey }
      return lhs.offset < rhs.offset
    }

    var accepted: [MarkdownTextPresentationAttachment] = []
    var rejected: [MarkdownTextPresentationRejectedAttachment] = []
    accepted.reserveCapacity(indexed.count)
    rejected.reserveCapacity(indexed.count)

    for (_, attachment) in indexed {
      let range = attachment.sourceRange
      let reason: MarkdownTextPresentationAttachmentRejectionReason?
      if range.location < 0 {
        reason = .negativeLocation
      } else if range.length < 0 {
        reason = .negativeLength
      } else if range.length == 0 {
        reason = .zeroLength
      } else if range.location > sourceLength
        || range.length > sourceLength - range.location
      {
        reason = .outOfBounds
      } else if let previous = accepted.last,
        NSIntersectionRange(previous.sourceRange, range).length > 0
      {
        reason = .overlapsAcceptedAttachment
      } else {
        reason = nil
      }

      if let reason {
        rejected.append(
          MarkdownTextPresentationRejectedAttachment(
            attachment: attachment,
            reason: reason
          )
        )
      } else {
        accepted.append(attachment)
      }
    }
    return NormalizedAttachments(accepted: accepted, rejected: rejected)
  }

  private static func canonicalKindKey(
    _ kind: MarkdownInlineAttachmentItem.Kind?
  ) -> String {
    guard let kind else { return "0:" }
    switch kind {
    case .image(let reference, let altText):
      return "1:\(reference)\u{1F}\(altText)"
    case .formula(let source, let displayMode):
      return "2:\(displayMode.rawValue)\u{1F}\(source)"
    }
  }

  private func lowerBoundSegmentStart(
    _ offset: Int,
    usePresentationRange: Bool
  ) -> Int {
    var lower = 0
    var upper = segments.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      let start = usePresentationRange
        ? segments[middle].presentationRange.location
        : segments[middle].sourceRange.location
      if start < offset {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }

  /// Locate the first segment whose end is strictly after `offset`.
  /// Segment ranges are sorted and non-empty, so this is the first segment
  /// that can intersect a non-empty query beginning at that offset.
  private func firstSegmentIndexWhoseEndExceeds(
    _ offset: Int,
    usePresentationRange: Bool
  ) -> Int {
    var lower = 0
    var upper = segments.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      let end = usePresentationRange
        ? NSMaxRange(segments[middle].presentationRange)
        : NSMaxRange(segments[middle].sourceRange)
      if end <= offset {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }

  private func isValidBoundaryRange(_ range: NSRange, upperBound: Int) -> Bool {
    guard range.location >= 0,
      range.length >= 0,
      range.location <= upperBound
    else { return false }
    return range.length <= upperBound - range.location
  }
}
