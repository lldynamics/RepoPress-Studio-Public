import SwiftUI

extension AIChatContextInspectorView {
  @ViewBuilder
  var connectionBlockerBanner: some View {
    if let codexPresentation = codexConnectionPresentation {
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Image(
            systemName: codexConnection.phase == .failed
              ? "exclamationmark.triangle" : "shippingbox"
          )
          .foregroundStyle(WorkbenchTheme.warning)
          Text(codexPresentation.title).font(.caption.weight(.semibold))
          Spacer(minLength: 8)
          if codexConnection.isChecking || codexConnection.isPreparing {
            ProgressView().controlSize(.small)
          }
        }
        Text(codexPresentation.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          if codexConnection.isChecking || codexConnection.isPreparing {
            if codexConnection.canCancelPreparation {
              Button(String(localized: "取消准备")) { codexConnection.cancelPreparation() }
                .controlSize(.small)
                .accessibilityIdentifier("ai-assistant-codex-connection-cancel")
            }
            Button(String(localized: "选择其他连接")) { openAICredentialsSettings() }
              .controlSize(.small)
          } else {
            if let action = codexPresentation.action,
              let actionTitle = codexPresentation.actionTitle
            {
              Button(actionTitle) { performCodexConnectionAction(action) }
                .controlSize(.small)
                .accessibilityIdentifier("ai-assistant-codex-connection-action")
            }
            if codexPresentation.action != .refresh {
              Button(String(localized: "重新检测")) {
                Task { await codexConnection.refresh() }
              }
              .controlSize(.small)
            }
          }
        }
      }
      .padding(.horizontal, WorkbenchSpacing.content)
      .padding(.vertical, WorkbenchSpacing.control)
      .background(
        WorkbenchTheme.warning.opacity(WorkbenchOpacity.noticeBackground),
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.panel, style: .continuous)
      )
      .padding(.horizontal, WorkbenchSpacing.card)
      .padding(.vertical, WorkbenchSpacing.control)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(codexPresentation.title)
      .accessibilityValue(codexPresentation.detail)
      .accessibilityIdentifier("ai-assistant-codex-connection-blocker")
    } else {
      HStack(alignment: .center, spacing: 10) {
        Image(
          systemName: connectionReadiness == .missingAPIKey
            ? "key.horizontal" : "exclamationmark.triangle"
        )
        .foregroundStyle(WorkbenchTheme.warning)
        Text(connectionReadiness.title).font(.caption.weight(.semibold))
        if AIChatConnectionBlockerPresentation.shouldShowDetail(
          title: connectionReadiness.title,
          detail: connectionReadiness.detail
        ) {
          Text(connectionReadiness.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Button(String(localized: "ai-assistant.configure")) { openAICredentialsSettings() }
          .controlSize(.small)
      }
      .padding(.horizontal, WorkbenchSpacing.content)
      .padding(.vertical, WorkbenchSpacing.control)
      .background(WorkbenchTheme.warning.opacity(WorkbenchOpacity.noticeBackground))
      .accessibilityElement(children: .contain)
      .accessibilityLabel(connectionReadiness.title)
      .accessibilityValue(connectionReadiness.detail)
    }
  }

  var codexConnectionPresentation: AIChatCodexConnectionPresentation.Configuration? {
    guard currentAIProviderConfig.usesCodexAppServer else { return nil }
    return AIChatCodexConnectionPresentation.configuration(
      phase: codexConnection.phase,
      progress: codexConnection.progress,
      failure: codexConnection.failure
    )
  }

  var shouldShowConnectionBlocker: Bool {
    currentAIProviderConfig.usesCodexAppServer
      ? codexConnectionPresentation != nil
        || (connectionReadiness != .ready && connectionReadiness != .noDraft)
      : connectionReadiness != .ready && connectionReadiness != .noDraft
  }

  var isCodexConnectionReadyForSending: Bool {
    guard connectionReadiness.isReady else { return false }
    guard currentAIProviderConfig.usesCodexAppServer else { return true }
    return codexConnection.phase.isReady
      && !codexConnection.isChecking
      && !codexConnection.isPreparing
  }

  func performCodexConnectionAction(_ action: AIChatCodexConnectionPresentation.Action) {
    switch action {
    case .prepare: codexConnection.prepare()
    case .refresh: Task { await codexConnection.refresh() }
    case .openSettings: openAICredentialsSettings()
    }
  }
}
