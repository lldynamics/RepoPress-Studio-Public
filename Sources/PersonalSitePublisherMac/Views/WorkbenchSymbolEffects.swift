import SwiftUI

private struct WorkbenchSyncSymbolEffectModifier: ViewModifier {
  let trigger: Int

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *), !reduceMotion {
      content.symbolEffect(.bounce, value: trigger)
    } else {
      content
    }
  }
}

private struct WorkbenchAIThinkingSymbolEffectModifier: ViewModifier {
  let isActive: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *), !reduceMotion {
      content.symbolEffect(
        .variableColor.iterative,
        options: .repeating,
        isActive: isActive
      )
    } else {
      content
    }
  }
}

extension View {
  func workbenchSyncSymbolEffect(trigger: Int) -> some View {
    modifier(WorkbenchSyncSymbolEffectModifier(trigger: trigger))
  }

  func workbenchAIThinkingSymbolEffect(isActive: Bool) -> some View {
    modifier(WorkbenchAIThinkingSymbolEffectModifier(isActive: isActive))
  }
}
