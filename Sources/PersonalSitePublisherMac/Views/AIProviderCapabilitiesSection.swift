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
          HStack(spacing: 8) {
            Image(systemName: systemImage(for: descriptor.capability))
              .foregroundStyle(color(for: descriptor.support))
              .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
              Text(verbatim: descriptor.localizedTitle)
                .font(.callout)
              Text(verbatim: descriptor.localizedSupportTitle)
                .font(.caption)
                .foregroundStyle(color(for: descriptor.support))
            }
          }
          .padding(.horizontal, 9)
          .padding(.vertical, 7)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            color(for: descriptor.support).opacity(0.08),
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          )
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            "\(descriptor.localizedTitle)：\(descriptor.localizedSupportTitle)"
          )
        }
      }
    } header: {
      Text("当前连接能力")
    } footer: {
      Text("“未知”表示应用可以尝试请求，但实际能力取决于接口或所选模型。")
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
}
