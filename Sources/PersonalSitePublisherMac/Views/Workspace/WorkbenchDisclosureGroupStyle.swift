import SwiftUI

/// A full-width disclosure button with a distinct accessibility identity.
/// Keeping the identity on the button preserves identifiers in its content.
struct WorkbenchDisclosureGroupStyle: DisclosureGroupStyle {
  let toggleIdentifier: String

  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
      Button {
        configuration.isExpanded.toggle()
      } label: {
        HStack(spacing: WorkbenchSpacing.control) {
          Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
            .font(.workbenchMetadata.weight(.semibold))
            .foregroundStyle(.workbenchSecondary)
            .frame(width: 12)
            .accessibilityHidden(true)
          configuration.label
          Spacer(minLength: 0)
        }
        .padding(.vertical, WorkbenchSpacing.icon)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier(toggleIdentifier)
      .accessibilityValue(configuration.isExpanded ? Text("已展开") : Text("已收起"))

      if configuration.isExpanded {
        configuration.content
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
