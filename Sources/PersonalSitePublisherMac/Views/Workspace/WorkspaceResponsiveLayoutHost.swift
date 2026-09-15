import SwiftUI

private struct WorkspaceResponsiveLayoutPreferenceKey: PreferenceKey {
  static let defaultValue = WorkspaceResponsiveLayoutSnapshot.initial

  static func reduce(
    value: inout WorkspaceResponsiveLayoutSnapshot,
    nextValue: () -> WorkspaceResponsiveLayoutSnapshot
  ) {
    value = nextValue()
  }
}

/// Keeps continuous window measurements in a leaf view. The preference value
/// compares by semantic layout band, so `ContentView` updates only at the
/// 960/1180/1240 point decisions instead of for every resize pixel.
private struct WorkspaceResponsiveLayoutReader: View {
  var body: some View {
    GeometryReader { geometry in
      Color.clear.preference(
        key: WorkspaceResponsiveLayoutPreferenceKey.self,
        value: WorkspaceResponsiveLayoutSnapshot(width: geometry.size.width)
      )
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct WorkspaceResponsiveLayoutHost<Content: View>: View {
  let content: Content
  let onChange: (WorkspaceResponsiveLayoutSnapshot) -> Void

  init(
    onChange: @escaping (WorkspaceResponsiveLayoutSnapshot) -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.content = content()
    self.onChange = onChange
  }

  var body: some View {
    content
      .background(WorkspaceResponsiveLayoutReader())
      .onPreferenceChange(WorkspaceResponsiveLayoutPreferenceKey.self, perform: onChange)
  }
}
