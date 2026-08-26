import AppKit
import Foundation
import OSLog

private enum MarkdownTextKit2ReadOnlyPresentationTelemetry {
  static let signposter = OSSignposter(
    subsystem: "com.jinfang.PersonalSitePublisherMac",
    category: "MarkdownReadOnlyPresentation"
  )
}

/// Opt-in gate for the blurred, derived TextKit 2 presentation document.
///
/// The feature remains off in ordinary builds while the interaction path is
/// being validated in real editor windows. Set the environment value to one
/// of the explicit truthy spellings to exercise it without changing the
/// persisted editor configuration.
enum MarkdownTextKit2ReadOnlyPresentationPolicy {
  static let environmentKey = "REPOPRESS_TEXTKIT2_READ_ONLY_PRESENTATION"

  static var isEnabled: Bool {
    isEnabled(environment: ProcessInfo.processInfo.environment)
  }

  static func isEnabled(environment: [String: String]) -> Bool {
    guard let rawValue = environment[environmentKey] else { return false }
    switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on":
      return true
    default:
      return false
    }
  }
}

extension MacMarkdownTextView.Coordinator {
  var isShowingReadOnlyPresentation: Bool {
    readOnlyPresentationDocument != nil
  }

  func updateReadOnlyPresentationPolicy(
    isEnabled: Bool,
    in textView: NSTextView
  ) {
    guard readOnlyNativePresentationEnabled != isEnabled else { return }
    readOnlyNativePresentationEnabled = isEnabled
    if !isEnabled {
      restoreEditableMarkdown(in: textView)
      readOnlyPresentationCachedOutput = nil
      readOnlyPresentationCachedBodyMarkdown = nil
      readOnlyPresentationCachedBodyUTF16Offset = nil
      readOnlyPresentationCachedAttachments.removeAll(keepingCapacity: false)
      readOnlyPresentationCachedAvailableWidth = nil
      readOnlyPresentationCachedBaseFontSize = nil
    }
  }

  func configureReadOnlyPresentationFocusBridge(
    on textView: DroppableMarkdownTextView
  ) {
    self.textView = textView
    textView.willBecomeFirstResponderHandler = { [weak self, weak textView] in
      guard let self, let textView else { return }
      self.restoreEditableMarkdown(in: textView)
    }
    textView.didResignFirstResponderHandler = { [weak self, weak textView] in
      guard let self, let textView else { return }
      self.scheduleReadOnlyPresentationIfNeeded(in: textView)
    }
  }

  func scheduleReadOnlyPresentationIfNeeded(in textView: NSTextView) {
    readOnlyPresentationTask?.cancel()
    readOnlyPresentationTask = nil
    guard readOnlyNativePresentationEnabled,
      !isShowingReadOnlyPresentation
    else { return }

    readOnlyPresentationTask = Task { @MainActor [weak self, weak textView] in
      // `resignFirstResponder()` completes its AppKit transition before the
      // derived document is installed. This also coalesces repeated SwiftUI
      // updates while the editor remains blurred.
      await Task.yield()
      guard !Task.isCancelled,
        let self,
        let textView,
        let window = textView.window,
        window.firstResponder !== textView,
        !textView.hasMarkedText()
      else { return }
      _ = self.showReadOnlyPresentation(in: textView)
      self.readOnlyPresentationTask = nil
    }
  }

  @discardableResult
  func showReadOnlyPresentation(in textView: NSTextView) -> Bool {
    guard readOnlyNativePresentationEnabled,
      !isShowingReadOnlyPresentation,
      textView.textLayoutManager != nil,
      !textView.hasMarkedText(),
      textView.window?.firstResponder !== textView,
      textView.string == representedText
    else {
      return false
    }

    let source = representedText
    let sourceLength = (source as NSString).length
    guard bodyUTF16Offset >= 0,
      bodyUTF16Offset <= sourceLength,
      (bodyMarkdown as NSString).length <= sourceLength - bodyUTF16Offset
    else {
      return false
    }
    let bodyRange = NSRange(
      location: bodyUTF16Offset,
      length: (bodyMarkdown as NSString).length
    )
    guard (source as NSString).substring(with: bodyRange) == bodyMarkdown else {
      return false
    }

    var presentationLength = 0
    var installedAttachmentCount = 0
    var reusedCachedOutput = false
    var cacheStatus = "miss-empty"
    var transitionResult = "failed"
    var transitionReason = "factory-output-invalid"
    let transitionInterval = MarkdownTextKit2ReadOnlyPresentationTelemetry.signposter
      .beginInterval(
        "ReadOnlyPresentationShow",
        id: MarkdownTextKit2ReadOnlyPresentationTelemetry.signposter.makeSignpostID(),
        "sourceUTF16Length: \(sourceLength, privacy: .public), requestedAttachmentCount: \(self.attachments.count, privacy: .public)"
      )
    defer {
      MarkdownTextKit2ReadOnlyPresentationTelemetry.signposter.endInterval(
        "ReadOnlyPresentationShow",
        transitionInterval,
        "result: \(transitionResult, privacy: .public), reason: \(transitionReason, privacy: .public), cacheHit: \(reusedCachedOutput, privacy: .public), cacheStatus: \(cacheStatus, privacy: .public), sourceUTF16Length: \(sourceLength, privacy: .public), presentationUTF16Length: \(presentationLength, privacy: .public), installedAttachmentCount: \(installedAttachmentCount, privacy: .public)"
      )
    }

    let visibleWidth = max(
      1,
      min(
        textView.textContainer?.containerSize.width ?? textView.bounds.width,
        textView.bounds.width > 0 ? textView.bounds.width : CGFloat(comfortConfiguration.bodyWidth)
      ) - (textView.textContainerInset.width * 2)
    )
    let baseFontSize = syntaxHighlightPalette.baseFont.pointSize
    var outputForReuse: MarkdownTextKit2ReadOnlyPresentationFactory.Output?
    if let cachedOutput = readOnlyPresentationCachedOutput {
      if cachedOutput.source != source {
        cacheStatus = "miss-source"
      } else if readOnlyPresentationCachedBodyMarkdown != bodyMarkdown
        || readOnlyPresentationCachedBodyUTF16Offset != bodyUTF16Offset
      {
        cacheStatus = "miss-body"
      } else if readOnlyPresentationCachedAttachments != attachments {
        cacheStatus = "miss-attachments"
      } else if let cachedAvailableWidth = readOnlyPresentationCachedAvailableWidth,
        abs(cachedAvailableWidth - visibleWidth) > 0.5
      {
        cacheStatus = "miss-width"
      } else if let cachedBaseFontSize = readOnlyPresentationCachedBaseFontSize,
        abs(cachedBaseFontSize - baseFontSize) > 0.01
      {
        cacheStatus = "miss-font"
      } else {
        outputForReuse = cachedOutput
        reusedCachedOutput = true
        cacheStatus = "hit"
      }
    }
    let output = outputForReuse
      ?? MarkdownTextKit2ReadOnlyPresentationFactory.make(
        fullSource: source,
        bodyMarkdown: bodyMarkdown,
        bodyUTF16Offset: bodyUTF16Offset,
        attachments: attachments,
        availableWidth: visibleWidth,
        baseFontSize: baseFontSize
      )
    presentationLength = output.document.attributedString.length
    installedAttachmentCount = output.document.installedAttachments.count
    guard output.source == source,
      let textStorage = textView.textStorage
    else {
      transitionReason = output.source == source ? "missing-text-storage" : "source-mismatch"
      return false
    }
    if !reusedCachedOutput {
      readOnlyPresentationCachedOutput = output
      readOnlyPresentationCachedBodyMarkdown = bodyMarkdown
      readOnlyPresentationCachedBodyUTF16Offset = bodyUTF16Offset
      readOnlyPresentationCachedAttachments = attachments
      readOnlyPresentationCachedAvailableWidth = visibleWidth
      readOnlyPresentationCachedBaseFontSize = baseFontSize
    }

    let sourceSelection = MacMarkdownTextView.clamped(
      textView.selectedRange(),
      length: sourceLength
    )
    let presentationSelection = output.document.presentationRange(
      forSourceRange: sourceSelection
    ) ?? NSRange(location: 0, length: 0)
    let attributedPresentation = NSMutableAttributedString(
      attributedString: output.document.attributedString
    )
    if attributedPresentation.length > 0 {
      attributedPresentation.addAttributes(
        syntaxHighlightPalette.defaultAttributes,
        range: NSRange(location: 0, length: attributedPresentation.length)
      )
    }

    // Preserve the already-highlighted editable source before the text storage
    // temporarily hosts the derived presentation. Reusing this snapshot on
    // refocus avoids resetting a long document to default attributes and then
    // immediately scheduling another full syntax pass while typing resumes.
    readOnlyPresentationEditableAttributedSnapshot = NSAttributedString(
      attributedString: textStorage
    )
    cancelReadOnlyPresentationTasks(keepingScheduledTask: true)
    suspendSyntaxHighlightingForReadOnlyPresentation(in: textView)
    readOnlyPresentationDocument = output.document
    readOnlyPresentationSourceSelection = sourceSelection
    isApplyingRepresentedText = true
    textStorage.setAttributedString(attributedPresentation)
    textView.setSelectedRange(
      MacMarkdownTextView.clamped(
        presentationSelection,
        length: attributedPresentation.length
      )
    )
    isApplyingRepresentedText = false
    textView.isEditable = false
    textView.isSelectable = true
    textView.usesFindBar = false
    textView.isIncrementalSearchingEnabled = false
    suspendGhostTextOverlay(ghostText, in: textView)
    (textView.enclosingScrollView as? MarkdownEditorScrollView)?
      .invalidateDocumentHeight(immediately: true)

    readOnlyPresentationImageTasks = output.imageLoads.map { request in
      Task { @MainActor [weak self, weak textView] in
        let payload = await MarkdownInlineAttachmentImageCache.shared.image(
          at: request.sourceURL
        )
        guard !Task.isCancelled,
          let self,
          let textView,
          self.readOnlyPresentationDocument === output.document,
          let payload
        else { return }
        request.attachment.updateImage(
          NSImage(cgImage: payload.image, size: .zero)
        )
        textView.needsDisplay = true
      }
    }
    if !output.imageLoads.isEmpty {
      MarkdownTextKit2ReadOnlyPresentationTelemetry.signposter.emitEvent(
        "ReadOnlyPresentationImageLoadsScheduled",
        "sourceUTF16Length: \(sourceLength, privacy: .public), presentationUTF16Length: \(presentationLength, privacy: .public), attachmentCount: \(installedAttachmentCount, privacy: .public), imageLoadCount: \(output.imageLoads.count, privacy: .public)"
      )
    }
    transitionResult = "installed"
    transitionReason = installedAttachmentCount == 0
      ? "semantic"
      : "installed"
    return true
  }

  func restoreEditableMarkdown(in textView: NSTextView) {
    readOnlyPresentationTask?.cancel()
    readOnlyPresentationTask = nil
    guard let document = readOnlyPresentationDocument else { return }

    let source = representedText
    let sourceLength = (source as NSString).length
    let presentationLength = document.attributedString.length
    let installedAttachmentCount = document.installedAttachments.count
    let editableAttributedSnapshot = readOnlyPresentationEditableAttributedSnapshot
    let canRestoreAttributedSnapshot = editableAttributedSnapshot?.string == source
    var transitionResult = "failed"
    var transitionReason = "unknown"
    let transitionInterval = MarkdownTextKit2ReadOnlyPresentationTelemetry.signposter
      .beginInterval(
        "ReadOnlyPresentationRestore",
        id: MarkdownTextKit2ReadOnlyPresentationTelemetry.signposter.makeSignpostID(),
        "sourceUTF16Length: \(sourceLength, privacy: .public), presentationUTF16Length: \(presentationLength, privacy: .public), attachmentCount: \(installedAttachmentCount, privacy: .public)"
      )
    defer {
      MarkdownTextKit2ReadOnlyPresentationTelemetry.signposter.endInterval(
        "ReadOnlyPresentationRestore",
        transitionInterval,
        "result: \(transitionResult, privacy: .public), reason: \(transitionReason, privacy: .public), sourceUTF16Length: \(sourceLength, privacy: .public), presentationUTF16Length: \(presentationLength, privacy: .public), attachmentCount: \(installedAttachmentCount, privacy: .public)"
      )
    }

    let mappedSelection = document.sourceRange(
      forPresentationRange: textView.selectedRange()
    ) ?? readOnlyPresentationSourceSelection
      ?? NSRange(location: 0, length: 0)
    let restoredSelection = MacMarkdownTextView.clamped(
      mappedSelection,
      length: sourceLength
    )

    cancelReadOnlyPresentationTasks(keepingScheduledTask: true)
    readOnlyPresentationDocument = nil
    readOnlyPresentationSourceSelection = nil
    readOnlyPresentationEditableAttributedSnapshot = nil
    isApplyingRepresentedText = true
    let attributedSource = editableAttributedSnapshot.flatMap { snapshot in
      snapshot.string == source ? snapshot : nil
    } ?? NSAttributedString(
      string: source,
      attributes: syntaxHighlightPalette.defaultAttributes
    )
    if let textStorage = textView.textStorage {
      textStorage.setAttributedString(attributedSource)
    } else {
      textView.string = source
    }
    textView.setSelectedRange(restoredSelection)
    isApplyingRepresentedText = false
    textView.isEditable = true
    textView.isSelectable = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    ghostTextOverlayView?.isHidden = ghostText.isEmpty
    refreshCachedTypingAttributes(in: textView)
    if canRestoreAttributedSnapshot {
      repaintVisibleSyntaxViewport(in: textView, reason: .viewport)
    } else {
      invalidateHighlightedTextCache(in: textView)
      scheduleMarkdownSyntaxHighlighting(for: textView, text: source)
    }
    updateDiagnostics(diagnostics, in: textView, force: true)
    updateCurrentParagraphHighlight(in: textView, force: true)
    (textView.enclosingScrollView as? MarkdownEditorScrollView)?
      .invalidateDocumentHeight(immediately: true)
    transitionResult = "restored"
    transitionReason = "become-first-responder"
  }

  func applyReadOnlyPresentationSelection(
    selectedRange: NSRange,
    isFrontMatterSelection: Bool,
    in textView: NSTextView
  ) {
    guard let document = readOnlyPresentationDocument,
      shouldApplyRepresentedSelection(
        selectedRange: selectedRange,
        isFrontMatterSelection: isFrontMatterSelection,
        in: textView
      )
    else { return }

    let sourceLength = (document.source as NSString).length
    let sourceRange: NSRange
    if isFrontMatterSelection {
      sourceRange = MacMarkdownTextView.clamped(selectedRange, length: sourceLength)
    } else {
      sourceRange = MacMarkdownTextView.clamped(
        NSRange(
          location: bodyUTF16Offset + selectedRange.location,
          length: selectedRange.length
        ),
        length: sourceLength
      )
    }
    guard let presentationRange = document.presentationRange(
      forSourceRange: sourceRange
    ) else { return }
    let clampedPresentationRange = MacMarkdownTextView.clamped(
      presentationRange,
      length: (textView.string as NSString).length
    )
    guard textView.selectedRange() != clampedPresentationRange else { return }
    isApplyingRepresentedText = true
    textView.setSelectedRange(clampedPresentationRange)
    isApplyingRepresentedText = false
    readOnlyPresentationSourceSelection = sourceRange
  }

  func suspendGhostTextOverlay(_ text: String, in textView: NSTextView) {
    updateGhostText(text, in: textView)
    ghostTextOverlayView?.isHidden = true
  }

  func cancelReadOnlyPresentationTasks(keepingScheduledTask: Bool = false) {
    if !keepingScheduledTask {
      readOnlyPresentationTask?.cancel()
      readOnlyPresentationTask = nil
    }
    readOnlyPresentationImageTasks.forEach { $0.cancel() }
    readOnlyPresentationImageTasks.removeAll(keepingCapacity: false)
  }
}
