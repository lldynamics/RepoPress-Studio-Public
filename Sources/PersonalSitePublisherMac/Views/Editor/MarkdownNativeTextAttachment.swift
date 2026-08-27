import AppKit

/// The character that AppKit uses as the storage token for an
/// ``NSTextAttachment``. Markdown source must never be rewritten to this
/// character just to obtain native attachment layout.
private let markdownNativeAttachmentCharacter: unichar = 0xFFFC

/// The native attachment bridge is intentionally conservative. TextKit 2
/// only consumes ``NSAttributedString.Key.attachment`` as an attachment when
/// the backing string already contains AppKit's replacement character. A
/// Markdown image or formula range contains ordinary source characters, so
/// applying the attribute to that range is ignored by AppKit and cannot be
/// used as a source-preserving bridge.
@MainActor
enum MarkdownNativeTextAttachmentSupport {
  static func canInstall(
    in textView: NSTextView,
    sourceRange: NSRange
  ) -> Bool {
    guard textView.textLayoutManager != nil,
      let storage = textView.textStorage,
      sourceRange.location != NSNotFound,
      sourceRange.length == 1,
      NSMaxRange(sourceRange) <= storage.length
    else {
      return false
    }
    return (storage.string as NSString).character(at: sourceRange.location)
      == markdownNativeAttachmentCharacter
  }

  /// Installs the attachment attribute only when AppKit's required storage
  /// token is already present. The caller can therefore keep the exact
  /// editable Markdown string and safely fall back to the existing viewport
  /// presentation for ordinary Markdown ranges.
  @discardableResult
  static func install(
    _ attachment: NSTextAttachment,
    in textView: NSTextView,
    sourceRange: NSRange
  ) -> Bool {
    guard canInstall(in: textView, sourceRange: sourceRange),
      let storage = textView.textStorage
    else {
      return false
    }

    storage.addAttribute(.attachment, value: attachment, range: sourceRange)
    guard
      let installedAttachment = storage.attribute(
        .attachment,
        at: sourceRange.location,
        effectiveRange: nil
      ) as? NSTextAttachment
    else {
      return false
    }
    return installedAttachment === attachment
  }

  static func remove(
    from textView: NSTextView,
    sourceRange: NSRange
  ) {
    guard let storage = textView.textStorage,
      sourceRange.location != NSNotFound,
      sourceRange.length == 1,
      NSMaxRange(sourceRange) <= storage.length
    else {
      return
    }
    storage.removeAttribute(.attachment, range: sourceRange)
  }
}

/// A TextKit 2 attachment whose view is owned by the layout manager. It is
/// never inserted into the text view with ``addSubview`` by the editor.
@MainActor
final class MarkdownNativeTextAttachment: NSTextAttachment {
  static let fileType = "com.lldynamics.repopress.markdown-text-attachment"

  let content: MarkdownInlineAttachmentOverlayView.Content
  // The provider callback is imported as nonisolated. Prepare the AppKit view
  // while this attachment is constructed on the main actor, so loadView only
  // hands an existing reference back to AppKit.
  nonisolated fileprivate let preparedView: MarkdownInlineAttachmentOverlayView

  init(
    content: MarkdownInlineAttachmentOverlayView.Content,
    bounds: NSRect
  ) {
    self.content = content
    let preparedView = MarkdownInlineAttachmentOverlayView(frame: bounds.standardized)
    preparedView.configure(content)
    self.preparedView = preparedView
    super.init(data: nil, ofType: nil)
    fileType = Self.fileType
    NSTextAttachment.registerViewProviderClass(
      MarkdownNativeTextAttachmentViewProvider.self,
      forFileType: Self.fileType
    )
    self.bounds = bounds
    allowsTextAttachmentView = true
  }

  /// Updates the already prepared image view after an asynchronous decode.
  ///
  /// TextKit 2 owns the provider view's placement. Updating that view in
  /// place keeps the attachment identity and presentation document stable,
  /// so an image load never adds a subview to the editor or rebuilds its text
  /// storage. Formula attachments intentionally ignore this method.
  func updateImage(_ image: NSImage?) {
    guard case .image = content else { return }
    preparedView.setImage(image)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func viewProvider(
    for parentView: NSView?,
    location: any NSTextLocation,
    textContainer: NSTextContainer?
  ) -> NSTextAttachmentViewProvider? {
    MarkdownNativeTextAttachmentViewProvider(
      textAttachment: self,
      parentView: parentView,
      textLayoutManager: textContainer?.textLayoutManager,
      location: location
    )
  }
}

/// Provider used by TextKit 2 for the native attachment path. AppKit owns the
/// provider's view placement. The editor may keep the provider alive for
/// content updates but does not add its view to the text view hierarchy.
@MainActor
final class MarkdownNativeTextAttachmentViewProvider: NSTextAttachmentViewProvider {
  override init(
    textAttachment: NSTextAttachment,
    parentView: NSView?,
    textLayoutManager: NSTextLayoutManager?,
    location: any NSTextLocation
  ) {
    super.init(
      textAttachment: textAttachment,
      parentView: parentView,
      textLayoutManager: textLayoutManager,
      location: location
    )
    tracksTextAttachmentViewBounds = true
  }

  nonisolated override func loadView() {
    guard let attachment = textAttachment as? MarkdownNativeTextAttachment else {
      view = nil
      return
    }
    view = attachment.preparedView
  }

  override func attachmentBounds(
    for attributes: [NSAttributedString.Key: Any],
    location: any NSTextLocation,
    textContainer: NSTextContainer?,
    proposedLineFragment: NSRect,
    position: NSPoint
  ) -> NSRect {
    (textAttachment as? MarkdownNativeTextAttachment)?.bounds ?? .zero
  }
}
