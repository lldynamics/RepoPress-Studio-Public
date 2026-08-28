import AppKit
import PublishingWorkbenchCore

/// A source-preserving, read-only TextKit 2 presentation document.
///
/// Markdown remains the only editable and persisted representation. This type
/// owns a derived attributed string whose attachment ranges use AppKit's
/// U+FFFC replacement character. It is intentionally not an editor model: do
/// not persist its `attributedString`, mutate it as a source document, or use
/// it as a second source of truth for input, undo, or saving.
@MainActor
final class MarkdownTextKit2PresentationDocument {
  /// A native attachment and the exact Markdown range it represents.
  ///
  /// The optional kind is copied into the core projection so callers can keep
  /// parser metadata next to the already prepared native attachment.
  struct Entry {
    let sourceRange: NSRange
    let kind: MarkdownInlineAttachmentItem.Kind?
    let attachment: MarkdownNativeTextAttachment

    init(
      sourceRange: NSRange,
      kind: MarkdownInlineAttachmentItem.Kind? = nil,
      attachment: MarkdownNativeTextAttachment
    ) {
      self.sourceRange = sourceRange
      self.kind = kind
      self.attachment = attachment
    }

    init(
      item: MarkdownInlineAttachmentItem,
      attachment: MarkdownNativeTextAttachment
    ) {
      self.init(
        sourceRange: item.range,
        kind: item.kind,
        attachment: attachment
      )
    }
  }

  /// Metadata for an attachment that was actually installed into the derived
  /// presentation string. Both ranges use UTF-16 offsets, matching AppKit.
  struct InstalledAttachment {
    let sourceRange: NSRange
    let presentationRange: NSRange
    let kind: MarkdownInlineAttachmentItem.Kind?
    let attachment: MarkdownNativeTextAttachment
  }

  /// An input entry that the projection rejected and therefore did not
  /// install. Keeping this metadata makes malformed parser output observable
  /// without weakening the source-preserving guard.
  struct RejectedEntry {
    let sourceRange: NSRange
    let kind: MarkdownInlineAttachmentItem.Kind?
    let attachment: MarkdownNativeTextAttachment
    let reason: MarkdownTextPresentationAttachmentRejectionReason
  }

  /// The exact Markdown source supplied by the caller. It is never rewritten
  /// to insert replacement characters.
  let source: String

  /// The reversible source-to-presentation mapping used by the document.
  let projection: MarkdownTextPresentationProjection

  /// The immutable TextKit 2 presentation string. Its string is derived from
  /// `projection.presentation`; it is not a persistence or editing source.
  let attributedString: NSAttributedString

  /// Source/presentation ranges and native attachment identities that were
  /// installed successfully, in presentation order.
  let installedAttachments: [InstalledAttachment]

  /// Entries rejected by range validation or overlap normalization.
  let rejectedEntries: [RejectedEntry]

  init(
    source: String,
    entries: [Entry] = [],
    attributes: [NSAttributedString.Key: Any] = [:]
  ) {
    self.source = source

    let projectionAttachments = entries.map {
      MarkdownTextPresentationAttachment(
        sourceRange: $0.sourceRange,
        kind: $0.kind
      )
    }
    let projection = MarkdownTextPresentationProjection(
      source: source,
      attachments: projectionAttachments
    )
    self.projection = projection

    let mutablePresentation = NSMutableAttributedString(
      string: projection.presentation,
      attributes: attributes.isEmpty ? nil : attributes
    )

    // The core projection intentionally contains value-only metadata. Resolve
    // each accepted value back to the corresponding native attachment through
    // keyed buckets so duplicate ranges remain deterministic without an O(k²)
    // scan.
    var entryBuckets: [MarkdownTextPresentationAttachment: [Int]] = [:]
    for (index, entry) in entries.enumerated() {
      let key = MarkdownTextPresentationAttachment(
        sourceRange: entry.sourceRange,
        kind: entry.kind
      )
      entryBuckets[key, default: []].append(index)
    }
    var bucketCursors: [MarkdownTextPresentationAttachment: Int] = [:]

    func nextEntry(
      for value: MarkdownTextPresentationAttachment
    ) -> Entry? {
      guard let bucket = entryBuckets[value] else { return nil }
      let cursor = bucketCursors[value, default: 0]
      guard cursor < bucket.count else { return nil }
      bucketCursors[value] = cursor + 1
      return entries[bucket[cursor]]
    }

    var installed: [InstalledAttachment] = []
    installed.reserveCapacity(projection.acceptedAttachments.count)
    // Walk the already-built segments once. Calling the range mapper once per
    // attachment would turn a large attachment plan into an O(k²) build.
    for segment in projection.segments where segment.isAttachment {
      guard let accepted = segment.attachment,
        let entry = nextEntry(for: accepted),
        segment.presentationRange.length == 1,
        NSMaxRange(segment.presentationRange) <= mutablePresentation.length
      else {
        continue
      }
      let presentationRange = segment.presentationRange

      mutablePresentation.addAttribute(
        .attachment,
        value: entry.attachment,
        range: presentationRange
      )
      let metadata = InstalledAttachment(
        sourceRange: accepted.sourceRange,
        presentationRange: presentationRange,
        kind: accepted.kind,
        attachment: entry.attachment
      )
      installed.append(metadata)
    }
    self.installedAttachments = installed

    var rejected: [RejectedEntry] = []
    rejected.reserveCapacity(projection.rejectedAttachments.count)
    for rejectedAttachment in projection.rejectedAttachments {
      guard let entry = nextEntry(for: rejectedAttachment.attachment) else {
        continue
      }
      rejected.append(
        RejectedEntry(
          sourceRange: rejectedAttachment.attachment.sourceRange,
          kind: rejectedAttachment.attachment.kind,
          attachment: entry.attachment,
          reason: rejectedAttachment.reason
        )
      )
    }
    self.rejectedEntries = rejected
    self.attributedString = NSAttributedString(attributedString: mutablePresentation)
  }

  /// Convert a source UTF-16 range into the derived presentation range.
  func presentationRange(
    forSourceRange sourceRange: NSRange,
    affinity: MarkdownTextPresentationAffinity = .downstream
  ) -> NSRange? {
    projection.presentationRange(forSourceRange: sourceRange, affinity: affinity)
  }

  /// Convert a derived presentation UTF-16 range back to its complete source
  /// Markdown range. Selecting U+FFFC returns the full source syntax range.
  func sourceRange(
    forPresentationRange presentationRange: NSRange,
    affinity: MarkdownTextPresentationAffinity = .downstream
  ) -> NSRange? {
    projection.sourceRange(
      forPresentationRange: presentationRange,
      affinity: affinity
    )
  }

  /// Find installed attachment metadata for a presentation character.
  func installedAttachment(
    atPresentationOffset presentationOffset: Int
  ) -> InstalledAttachment? {
    guard projection.attachment(atPresentationOffset: presentationOffset) != nil else {
      return nil
    }

    // `installedAttachments` follows the projection's presentation order.
    // Keep this lookup logarithmic for large documents instead of scanning
    // every attachment when hit-testing or resolving a selection.
    var lowerBound = 0
    var upperBound = installedAttachments.count
    while lowerBound < upperBound {
      let middle = lowerBound + (upperBound - lowerBound) / 2
      if installedAttachments[middle].presentationRange.location < presentationOffset {
        lowerBound = middle + 1
      } else {
        upperBound = middle
      }
    }
    guard lowerBound < installedAttachments.count else { return nil }
    let candidate = installedAttachments[lowerBound]
    guard presentationOffset >= candidate.presentationRange.location,
      presentationOffset < NSMaxRange(candidate.presentationRange)
    else {
      return nil
    }
    return candidate
  }
}
