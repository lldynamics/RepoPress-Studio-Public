import AppKit
import Combine

@MainActor
enum MarkdownEditorDocumentGeometry {
  /// Check exact insertion geometry after a native reveal or lazy layout.
  /// An existing input reveal still owns that caret until
  /// the scroll view cancels it for a user scroll, focus or selection change.
  static func revealSelection(in textView: NSTextView, native: Bool) {
    if native {
      textView.scrollRangeToVisible(textView.selectedRange())
    }
    guard textView.selectedRange().length == 0,
      let scrollView = textView.enclosingScrollView,
      let manager = textView.textLayoutManager,
      let range = MarkdownTextKit2RangeAdapter.textRange(
        for: textView.selectedRange(), in: textView)
    else { return }
    manager.ensureLayout(for: range)
    var insertionRect: NSRect?
    manager.enumerateTextSegments(in: range, type: .standard, options: []) {
      _, rect, _, _ in
      guard rect.height > 0 else { return true }
      insertionRect = insertionRevealRect(
        rect, textContainerOrigin: textView.textContainerOrigin,
        viewport: scrollView.documentVisibleRect)
      return false
    }
    if let insertionRect {
      textView.scrollToVisible(insertionRect)
    }
  }

  nonisolated static func insertionRevealRect(
    _ rect: NSRect, textContainerOrigin: NSPoint, viewport: NSRect
  ) -> NSRect? {
    guard rect.minX.isFinite, rect.minY.isFinite,
      rect.size.width.isFinite, rect.size.width >= 0,
      rect.size.height.isFinite, rect.size.height > 0,
      textContainerOrigin.x.isFinite, textContainerOrigin.y.isFinite,
      viewport.minX.isFinite, viewport.minY.isFinite,
      viewport.width.isFinite, viewport.width > 0,
      viewport.height.isFinite, viewport.height > 0
    else { return nil }
    let insertionRect = NSRect(
      x: rect.minX + textContainerOrigin.x,
      y: rect.minY + textContainerOrigin.y,
      width: max(rect.width, 1), height: rect.height)
    return viewport.intersects(insertionRect) ? nil : insertionRect
  }

  static func height(in textView: NSTextView) -> CGFloat? {
    guard let layoutManager = textView.textLayoutManager else { return nil }
    let verticalInsets = textView.textContainerOrigin.y + textView.textContainerInset.height
    var terminalHeight: CGFloat?
    // Usage bounds can retain the old document extent after deleting text.
    // Resolve only the current terminal fragment; its tiling frame includes
    // paragraph margins that the final glyph's typographic rectangle omits.
    layoutManager.enumerateTextLayoutFragments(
      from: layoutManager.documentRange.endLocation,
      options: [.reverse, .ensuresLayout, .ensuresExtraLineFragment]
    ) { fragment in
      let height = fragment.layoutFragmentFrame.maxY + verticalInsets
      if fragment.state == .layoutAvailable, height.isFinite, height > 0 {
        terminalHeight = height
      }
      return false
    }
    // The insertion segment accounts for an empty final line without laying
    // out the entire document or moving the selection/viewport.
    let endRange = NSTextRange(location: layoutManager.documentRange.endLocation)
    layoutManager.ensureLayout(for: endRange)
    layoutManager.enumerateTextSegments(in: endRange, type: .standard, options: []) {
      _, rect, _, _ in
      let height = rect.maxY + verticalInsets
      if rect.height > 0, height.isFinite {
        terminalHeight = max(terminalHeight ?? 0, height)
      }
      return true
    }

    let usageHeight =
      layoutManager.usageBoundsForTextContainer.maxY + textView.textContainerInset.height * 2
    let height = terminalHeight ?? usageHeight
    return height.isFinite ? max(0, height) : nil
  }

  static func ensureSelectionLayout(in textView: NSTextView) {
    let length = (textView.string as NSString).length
    let location = min(max(0, textView.selectedRange().location - 1), max(0, length - 1))
    let range = NSRange(location: location, length: min(1, length))
    if let textRange = MarkdownTextKit2RangeAdapter.textRange(for: range, in: textView) {
      textView.textLayoutManager?.ensureLayout(for: textRange)
    }
  }

  /// TextKit can revise its lazy height after syntax attributes or viewport
  /// layout change. Invalidate the owner's cache on the next main-loop turn,
  /// without reentering layout or cancelling its resize/selection requests.
  @MainActor
  final class Observer {
    private weak var manager: NSTextLayoutManager?
    private var observation: NSKeyValueObservation?
    private var storageObservation: AnyCancellable?
    private var generation = 0
    private var lastHeight: CGFloat = 0
    private var invalidationScheduled = false
    private var onChange: (@MainActor () -> Void)?

    func observe(_ manager: NSTextLayoutManager?, onChange: @escaping @MainActor () -> Void) {
      guard self.manager !== manager else { return }
      observation = nil
      storageObservation = nil
      self.manager = manager
      self.onChange = onChange
      generation += 1
      invalidationScheduled = false
      guard let manager else { return }
      lastHeight = manager.usageBoundsForTextContainer.maxY
      let generation = generation
      // Older TextKit versions can omit the usage-bounds notification when
      // attribute edits shrink the layout. Storage edits are an independent
      // invalidation source; coalesce them without reentering text processing.
      if let storage = (manager.textContentManager as? NSTextContentStorage)?.textStorage {
        storageObservation = NotificationCenter.default.publisher(
          for: NSTextStorage.didProcessEditingNotification, object: storage
        ).sink { [weak self] _ in
          Task { @MainActor [weak self] in
            self?.scheduleInvalidation(generation: generation)
          }
        }
      }
      observation = manager.observe(\.usageBoundsForTextContainer, options: [.new]) {
        [weak self] _, change in
        guard let height = change.newValue?.maxY else { return }
        Task { @MainActor [weak self] in
          self?.heightDidChange(to: height, generation: generation)
        }
      }
    }

    private func heightDidChange(to height: CGFloat, generation: Int) {
      guard generation == self.generation, height.isFinite,
        abs(height - lastHeight) > 0.5
      else { return }
      lastHeight = height
      scheduleInvalidation(generation: generation)
    }

    private func scheduleInvalidation(generation: Int) {
      guard generation == self.generation, !invalidationScheduled else { return }
      invalidationScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self, generation == self.generation else { return }
        self.invalidationScheduled = false
        self.onChange?()
      }
    }
  }
}
