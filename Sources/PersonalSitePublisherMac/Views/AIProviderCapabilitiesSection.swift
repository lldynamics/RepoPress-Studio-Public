import PublishingWorkbenchCore
import SwiftUI

struct AIProviderCapabilitiesSection: View {
  let config: AIProviderConfig

  private let columns = [
    GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 8)
  ]

  var body: some View {
    Section {
      LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
        ForEach(config.capabilityDescriptors) { descriptor in
          capabilityCell(
            title: descriptor.localizedTitle,
            support: descriptor.support,
            evidenceState: descriptor.evidenceState,
            probeOutcome: descriptor.probeOutcome,
            image: systemImage(for: descriptor.capability)
          )
        }
        ForEach(config.protocolCapabilityDescriptors) { descriptor in
          capabilityCell(
            title: descriptor.localizedTitle,
            support: descriptor.support,
            evidenceState: descriptor.evidenceState,
            probeOutcome: descriptor.probeOutcome,
            image: systemImage(for: descriptor.capability)
          )
        }
      }
    } header: {
      Text("当前连接能力")
    } footer: {
      Text("静态推断不等于实测；只有当前未过期的探测证据或可信静态支持才会启用可选字段。已过期和未知能力均按安全降级处理。")
    }
  }

  private func systemImage(for capability: AIProviderCapability) -> String {
    switch capability {
    case .chat:
      return "bubble.left.and.bubble.right"
    case .streamingResponse:
      return "text.line.first.and.arrowtriangle.forward"
    case .visionInput:
      return "photo"
    case .reasoningControl:
      return "brain"
    case .localService:
      return "desktopcomputer"
    case .modelDiscovery:
      return "magnifyingglass"
    }
  }

  private func color(for support: AIProviderCapabilitySupport) -> Color {
    switch support {
    case .supported:
      return WorkbenchTheme.success
    case .unsupported:
      return .secondary
    case .unknown:
      return WorkbenchTheme.warning
    }
  }

  private func systemImage(for capability: AIProviderProtocolCapability) -> String {
    switch capability {
    case .toolCalling:
      return "wrench.and.screwdriver"
    case .structuredOutput:
      return "curlybraces"
    }
  }

  private func capabilityCell(
    title: String,
    support: AIProviderCapabilitySupport,
    evidenceState: AIProviderCapabilityEvidenceState,
    probeOutcome: AIProviderCapabilityProbeOutcome?,
    image: String
  ) -> some View {
    HStack(spacing: 8) {
      Image(systemName: image)
        .foregroundStyle(color(for: support))
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: title)
          .font(.callout)
        Text(verbatim: supportTitle(support, state: evidenceState, outcome: probeOutcome))
          .font(.caption)
          .foregroundStyle(color(for: support))
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      color(for: support).opacity(0.08),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(title)：\(supportTitle(support, state: evidenceState, outcome: probeOutcome))"
    )
  }

  private func supportTitle(
    _ support: AIProviderCapabilitySupport,
    state: AIProviderCapabilityEvidenceState,
    outcome: AIProviderCapabilityProbeOutcome?
  ) -> String {
    if state == .probed, outcome == .inconclusive {
      return "\(CoreL10n.text(support.localizationKey)) · \(localizedEvidenceStateName(state))（结果不确定）"
    }
    return "\(CoreL10n.text(support.localizationKey)) · \(localizedEvidenceStateName(state))"
  }

  private func localizedEvidenceStateName(
    _ state: AIProviderCapabilityEvidenceState
  ) -> String {
    switch state {
    case .staticInference:
      return CoreL10n.text("静态推断")
    case .probed:
      return CoreL10n.text("已探测")
    case .unknown:
      return CoreL10n.text("未知")
    case .expired:
      return CoreL10n.text("已过期")
    }
  }
}
