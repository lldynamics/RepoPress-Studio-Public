import PublishingCoreSupport

extension MacMarkdownTextView.Coordinator {
  func scheduleBindingFlush() {
    bindingFlushTask?.cancel()
    let clock = bindingFlushClock
    bindingFlushTask = Task { @MainActor [weak self] in
      do {
        try await clock.sleep(for: DebounceIntervals.markdownBindingFlush)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      self?.flushPendingBindingWrites()
    }
  }

  func waitForPendingBindingFlush() async {
    await bindingFlushTask?.value
  }
}
