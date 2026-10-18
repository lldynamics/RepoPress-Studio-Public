import SwiftUI

extension View {
  /// Exposes this view as its own accessibility container. Applied directly
  /// to a view whose only child is already a container, SwiftUI merges the
  /// modifiers into that child and replaces the child's identifier. A hidden
  /// sibling layer keeps the two containers distinct. The sibling fills the
  /// proposed size, so use this only on views that already fill their space.
  func workbenchAccessibilityContainer(
    identifier: String,
    label: Text? = nil
  ) -> some View {
    modifier(WorkbenchAccessibilityContainerModifier(identifier: identifier, label: label))
  }
}

private struct WorkbenchAccessibilityContainerModifier: ViewModifier {
  let identifier: String
  let label: Text?

  func body(content: Content) -> some View {
    let container = ZStack {
      Color.clear
        .accessibilityHidden(true)
      content
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(identifier)

    if let label {
      container.accessibilityLabel(label)
    } else {
      container
    }
  }
}
