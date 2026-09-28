import SwiftUI

struct MarkdownEditorToolbarButtonStyle: ButtonStyle {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  let showsTitle: Bool
  var isSelected = false
  @Environment(\.isFocused) private var isFocused

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.workbenchButtonLabel)
      .padding(.horizontal, showsTitle ? 8 : 6)
      .frame(minWidth: showsTitle ? nil : 30, minHeight: 30)
      .fixedSize(horizontal: showsTitle, vertical: false)
      .background(
        isSelected
          ? workbenchAccentColor.opacity(configuration.isPressed ? 0.18 : 0.10)
          : Color.primary.opacity(configuration.isPressed ? 0.10 : 0.04),
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
      .overlay {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .stroke(
            isFocused
              ? workbenchAccentColor : (isSelected ? workbenchAccentColor.opacity(0.70) : .clear),
            lineWidth: isFocused ? 2 : (isSelected ? 1 : 0)
          )
      }
  }

}
