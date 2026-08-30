import SwiftUI

private struct WorkbenchTaskCompletionSymbolEffectModifier: ViewModifier {
  let trigger: Int

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @ViewBuilder
  func body(content: Content) -> some View {
    let style = WorkbenchMotionPolicy(reduceMotion: reduceMotion).style(for: .taskCompletion)
    if style == .completionBounce {
      content.symbolEffect(.bounce, value: trigger)
    } else {
      content
    }
  }
}

extension View {
  func workbenchTaskCompletionSymbolEffect(trigger: Int) -> some View {
    modifier(WorkbenchTaskCompletionSymbolEffectModifier(trigger: trigger))
  }
}
