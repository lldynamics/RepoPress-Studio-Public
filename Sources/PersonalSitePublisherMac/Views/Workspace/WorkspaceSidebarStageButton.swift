import SwiftUI

/// A full-width source-list row shared by the operational workspace pages.
struct WorkspaceSidebarStageButton: View {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  let title: LocalizedStringKey
  let systemImage: String
  let isSelected: Bool
  var isDisabled = false
  let help: String
  let identifier: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .frame(width: 16)
          .accessibilityHidden(true)
        Text(title)
          .font(.workbenchButtonLabel)
          .lineLimit(1)
        Spacer(minLength: 4)
      }
      .foregroundStyle(isSelected ? workbenchAccentColor : Color.primary)
      .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
      .padding(.horizontal, 10)
      .background {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .fill(
            isSelected
              ? workbenchAccentColor.opacity(WorkbenchOpacity.accentBackground)
              : Color.clear
          )
      }
      .contentShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    }
    .buttonStyle(WorkbenchFocusRingButtonStyle())
    .disabled(isDisabled)
    .help(help)
    .accessibilityLabel(Text(title))
    .accessibilityValue(isSelected ? "已选中" : "未选中")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier(identifier)
  }
}
