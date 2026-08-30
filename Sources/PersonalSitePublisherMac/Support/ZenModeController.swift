import AppKit
import Combine
import SwiftUI

/// The visibility decision is kept separate from the view so keyboard and
/// assistive-technology paths can be tested without rendering a window.
struct ZenModeToolbarVisibilityPolicy: Equatable, Sendable {
  let isZenModeActive: Bool
  let isPointerHovering: Bool
  let isKeyboardNavigationActive: Bool
  let isVoiceOverEnabled: Bool
  let isRecentlyTyped: Bool

  var toolbarOpacity: Double {
    guard isZenModeActive else { return 1.0 }
    if isPointerHovering || isKeyboardNavigationActive || isVoiceOverEnabled {
      return 1.0
    }
    return isRecentlyTyped ? 0.08 : 0.40
  }

}

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

  /// A session is started by an explicit Tab/arrow-key event in a toolbar.
  /// It intentionally does not claim that a particular descendant is focused.
  @Published private(set) var isKeyboardNavigationActive = false {
    didSet { recalculateToolbarOpacity() }
  }

  @Published private(set) var isVoiceOverEnabled: Bool
  @Published private(set) var isReduceMotionEnabled: Bool

  @Published private(set) var toolbarOpacity: Double = 1.0

  private var typingTimer: Task<Void, Never>?
  private var hoverExitTask: Task<Void, Never>?
  private var pendingHoverState: Bool?
  private let hoverExitDelayNanoseconds: UInt64

  init(
    voiceOverEnabled: Bool = NSWorkspace.shared.isVoiceOverEnabled,
    reduceMotionEnabled: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  ) {
    isVoiceOverEnabled = voiceOverEnabled
    isReduceMotionEnabled = reduceMotionEnabled
    hoverExitDelayNanoseconds = 180_000_000
    recalculateToolbarOpacity()
  }

  init(
    voiceOverEnabled: Bool,
    reduceMotionEnabled: Bool,
    hoverExitDelayNanoseconds: UInt64
  ) {
    isVoiceOverEnabled = voiceOverEnabled
    isReduceMotionEnabled = reduceMotionEnabled
    self.hoverExitDelayNanoseconds = hoverExitDelayNanoseconds
    recalculateToolbarOpacity()
  }

  private func recalculateToolbarOpacity() {
    toolbarOpacity =
      ZenModeToolbarVisibilityPolicy(
        isZenModeActive: isZenModeActive,
        isPointerHovering: isHovered,
        isKeyboardNavigationActive: isKeyboardNavigationActive,
        isVoiceOverEnabled: isVoiceOverEnabled,
        isRecentlyTyped: isRecentlyTyped
      ).toolbarOpacity
  }

  func refreshAccessibilityState(
    voiceOverEnabled: Bool? = nil,
    reduceMotionEnabled: Bool? = nil
  ) {
    isVoiceOverEnabled = voiceOverEnabled ?? NSWorkspace.shared.isVoiceOverEnabled
    let shouldReduceMotion =
      reduceMotionEnabled
      ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    isReduceMotionEnabled = shouldReduceMotion
    if shouldReduceMotion {
      settlePendingHoverWithoutAnimation()
    }
    recalculateToolbarOpacity()
  }

  /// Tests and the SwiftUI environment can provide an explicit state without
  /// pretending that VoiceOver or Reduce Motion can be inferred from focus.
  func setAccessibilityState(voiceOverEnabled: Bool, reduceMotionEnabled: Bool) {
    isVoiceOverEnabled = voiceOverEnabled
    isReduceMotionEnabled = reduceMotionEnabled
    if reduceMotionEnabled {
      settlePendingHoverWithoutAnimation()
    }
    recalculateToolbarOpacity()
  }

  func beginKeyboardNavigation() {
    isKeyboardNavigationActive = true
  }

  func endKeyboardNavigation() {
    isKeyboardNavigationActive = false
  }

  func updateHovered(_ hovered: Bool) {
    hoverExitTask?.cancel()
    hoverExitTask = nil
    pendingHoverState = hovered
    if hovered {
      pendingHoverState = nil
      if !isHovered {
        isHovered = true
      }
    } else if isReduceMotionEnabled {
      pendingHoverState = nil
      isHovered = false
    } else {
      hoverExitTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: self.hoverExitDelayNanoseconds)
        guard !Task.isCancelled else { return }
        guard self.pendingHoverState == false else { return }
        self.pendingHoverState = nil
        self.hoverExitTask = nil
        self.isHovered = false
      }
    }
  }

  private func settlePendingHoverWithoutAnimation() {
    hoverExitTask?.cancel()
    hoverExitTask = nil
    if let pendingHoverState {
      isHovered = pendingHoverState
    }
    self.pendingHoverState = nil
  }

  func handleTypingActivity() {
    // Returning to the editor ends the toolbar's keyboard navigation session.
    endKeyboardNavigation()
    guard isZenModeActive else { return }
    if !isRecentlyTyped {
      isRecentlyTyped = true
    }
    typingTimer?.cancel()
    typingTimer = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }
      self.isRecentlyTyped = false
    }
  }

  func toggleZenMode() {
    endKeyboardNavigation()
    isZenModeActive.toggle()
  }

  func toggleFormattingBar() {
    isFormattingBarVisible.toggle()
  }
}
