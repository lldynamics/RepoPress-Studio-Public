import Combine
import SwiftUI

@MainActor
final class ZenModeController: ObservableObject {
  @Published var isZenModeActive: Bool = false
  @Published var isFormattingBarVisible: Bool = true
  @Published var isTyping: Bool = false
  @Published var isHovered: Bool = false

  private var typingTimer: Task<Void, Never>?
  private var hoverExitTask: Task<Void, Never>?

  var toolbarOpacity: Double {
    if !isZenModeActive { return 1.0 }
    if isHovered { return 1.0 }
    if isTyping { return 0.08 }
    return 0.40
  }

  func updateHovered(_ hovered: Bool) {
    hoverExitTask?.cancel()
    if hovered {
      if !isHovered {
        withAnimation(.easeOut(duration: 0.15)) {
          isHovered = true
        }
      }
    } else {
      hoverExitTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 180_000_000)
        guard !Task.isCancelled else { return }
        withAnimation(.easeIn(duration: 0.25)) {
          self.isHovered = false
        }
      }
    }
  }

  func handleTypingActivity() {
    guard isZenModeActive else { return }
    if !isTyping {
      withAnimation(.easeInOut(duration: 0.25)) {
        isTyping = true
      }
    }
    typingTimer?.cancel()
    typingTimer = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 0.35)) {
        self.isTyping = false
      }
    }
  }

  func toggleZenMode() {
    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
      isZenModeActive.toggle()
    }
  }

  func toggleFormattingBar() {
    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
      isFormattingBarVisible.toggle()
    }
  }
}
