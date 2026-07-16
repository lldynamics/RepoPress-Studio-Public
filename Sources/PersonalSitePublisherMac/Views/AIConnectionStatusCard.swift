import PublishingWorkbenchCore
import SwiftUI

struct AIConnectionStatusCard: View {
  let config: AIProviderConfig
  let tokenAvailability: KeychainTokenAvailability
  let report: AIConnectionTestReport?

  var body: some View {
    let presentation = AISettingsConnectionPresentationService.presentation(
      config: config,
      tokenAvailability: tokenAvailability,
      report: report
    )

    return VStack(alignment: .leading, spacing: 6) {
      Label(presentation.title, systemImage: presentation.systemImage)
        .font(.callout.weight(.semibold))
        .foregroundStyle(aiConnectionStatusColor(presentation.level))

      Text(presentation.message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      Text(presentation.footnote)
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      aiConnectionStatusColor(presentation.level).opacity(WorkbenchOpacity.warningBackground),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
  }

  private func aiConnectionStatusColor(_ level: AISettingsConnectionStatusLevel) -> Color {
    switch level {
    case .success:
      return WorkbenchTheme.success
    case .warning:
      return WorkbenchTheme.warning
    case .info:
      return .secondary
    }
  }
}
