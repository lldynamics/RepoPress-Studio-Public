import Combine
import SwiftUI

@MainActor
final class ZenModeController: ObservableObject {
  @Published var isZenModeActive: Bool = false {
    didSet { recalculateToolbarOpacity() }
  }
  @Published var isFormattingBarVisible: Bool = true

  /// 标识用户在近 2 秒内是否有击键输入，用于驱动禅模式下工具栏的淡出
  @Published var isRecentlyTyped: Bool = false {
    didSet { recalculateToolbarOpacity() }
  }

  @available(*, deprecated, renamed: "isRecentlyTyped")
  var isTyping: Bool {
    get { isRecentlyTyped }
    set { isRecentlyTyped = newValue }
  }

  @Published var isHovered: Bool = false {
    didSet { recalculateToolbarOpacity() }
  }

  @Published private(set) var toolbarOpacity: Double = 1.0

  private var typingTimer: Task<Void, Never>?
  private var hoverExitTask: Task<Void, Never>?

  private func recalculateToolbarOpacity() {
    if !isZenModeActive {
      toolbarOpacity = 1.0
    } else if isHovered {
      toolbarOpacity = 1.0
    } else if isRecentlyTyped {
      toolbarOpacity = 0.08
    } else {
      toolbarOpacity = 0.40
    }
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
    if !isRecentlyTyped {
      withAnimation(.easeInOut(duration: 0.25)) {
        isRecentlyTyped = true
      }
    }
    typingTimer?.cancel()
    typingTimer = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 0.35)) {
        self.isRecentlyTyped = false
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
