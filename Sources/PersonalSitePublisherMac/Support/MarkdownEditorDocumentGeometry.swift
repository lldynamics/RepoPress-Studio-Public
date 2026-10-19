import AppKit
import Combine

@MainActor
enum MarkdownEditorDocumentGeometry {
  static func height(in textView: NSTextView) -> CGFloat? {
    guard let layoutManager = textView.textLayoutManager else { return nil }
    let source = textView.string as NSString
    var tailHeight: CGFloat = 0
    if source.length > 0 {
      // A cold viewport can expose only its laid-out prefix as the usage
      // bound. Resolve the final fragment before caching the scroll extent,
      // without requesting full-document line layout or moving the caret.
      let tailRange = source.rangeOfComposedCharacterSequence(at: source.length - 1)
      if let rect = MarkdownTextKit2RangeAdapter.rect(for: tailRange, in: textView) {
        tailHeight = rect.maxY + textView.textContainerInset.height
      }
      if let endRange = MarkdownTextKit2RangeAdapter.textRange(
        for: NSRange(location: source.length, length: 0), in: textView)
      {
        layoutManager.ensureLayout(for: endRange)
        layoutManager.enumerateTextSegments(in: endRange, type: .standard, options: []) {
          _, rect, _, _ in
          if rect.height > 0 {
            tailHeight = max(
              tailHeight,
              rect.maxY + textView.textContainerOrigin.y
                + textView.textContainerInset.height)
          }
          return true
        }
      }
    }
    let usageHeight =
      layoutManager.usageBoundsForTextContainer.maxY + textView.textContainerInset.height * 2
    let height = max(usageHeight, tailHeight)
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
