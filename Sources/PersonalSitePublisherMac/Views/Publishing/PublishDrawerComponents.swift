import PublishingWorkbenchCore
import SwiftUI

struct PublishDrawerCard<Content: View>: View {
  let title: String
  let systemImage: String
  let content: Content

  init(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(LocalizedStringKey(title), systemImage: systemImage)
        .font(.workbenchBody.weight(.semibold))

      content

      Spacer(minLength: 0)
    }
    .padding(WorkbenchSpacing.card)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(
      WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(LocalizedStringKey(title)))
  }
}

extension PreflightSeverity {
  var publishDrawerSystemImage: String {
    switch self {
    case .error:
      return "xmark.octagon"
    case .warning:
      return "exclamationmark.triangle"
    case .info:
      return "checkmark.circle"
    }
  }

  var publishDrawerColor: Color {
    switch self {
    case .error:
      return WorkbenchTheme.risk
    case .warning:
      return WorkbenchTheme.warning
    case .info:
      return WorkbenchTheme.success
    }
  }
}
