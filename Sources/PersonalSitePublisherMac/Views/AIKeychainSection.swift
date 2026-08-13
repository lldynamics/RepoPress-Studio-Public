import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct AIKeychainSection: View {
  let aiAPIKeyInput: Binding<String>
  let shouldFocusInput: Bool
  let navigationRequestID: UUID
  let config: AIProviderConfig
  let storageMode: AICredentialStorageMode
  let tokenAvailability: KeychainTokenAvailability
  let actionMessage: String?
  let onSaveAPIKey: () -> Void
  let onDeleteAPIKey: () -> Void
  let onRefreshState: () -> Void
  let onChangeStorageMode: @MainActor @Sendable (AICredentialStorageMode) -> Void
  @FocusState private var isAPIKeyFocused: Bool
  @State private var isDeleteConfirmationPresented = false
  @State private var isKeyRevealed = false

  var body: some View {
    Section("1. API Key") {
      Picker("保存位置", selection: storageModeBinding) {
        ForEach(AICredentialStorageMode.allCases) { mode in
          Text(storageModeTitle(mode)).tag(mode)
        }
      }
      .accessibilityLabel("AI API Key 保存位置")
      .accessibilityHint("只有选择系统钥匙串后，AI 功能才会访问钥匙串中的 API Key")

      HStack(spacing: 8) {
        if isKeyRevealed {
          TextField("API Key", text: aiAPIKeyInput)
            .focused($isAPIKeyFocused)
            .font(.body.monospaced())
            .accessibilityLabel("AI API Key")
        } else {
          SecureField("API Key", text: aiAPIKeyInput)
            .focused($isAPIKeyFocused)
            .accessibilityLabel("AI API Key")
        }

        Button {
          isKeyRevealed.toggle()
        } label: {
          Image(systemName: isKeyRevealed ? "eye.slash" : "eye")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(
          isKeyRevealed
            ? String(localized: "隐藏 API Key")
            : String(localized: "显示 API Key 明文")
        )
        .accessibilityLabel(
          isKeyRevealed
            ? String(localized: "隐藏 API Key")
            : String(localized: "显示 API Key 明文")
        )
      }
      .accessibilityLabel("AI API Key")
      .accessibilityHint("输入后保存到\(storageModeTitle(storageMode))")

      Button(saveButtonTitle) {
        onSaveAPIKey()
      }
      .workbenchProminentActionStyle()
      .disabled(aiAPIKeyInput.wrappedValue.trimmedForPublishing.isEmpty)
      .accessibilityLabel("保存 AI API Key")

      HStack {
        Label(
          tokenStatusTitle,
          systemImage: tokenStatusSystemImage
        )
        .foregroundStyle(tokenStatusColor)

        Spacer()

        Button("刷新状态") {
          onRefreshState()
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("刷新 AI Key 状态")

        Button("删除", role: .destructive) {
          isDeleteConfirmationPresented = true
        }
        .buttonStyle(.borderless)
        .disabled(!tokenAvailability.hasToken)
        .accessibilityLabel("删除 AI API Key")
      }

      if let accessFailureMessage = tokenAvailability.accessFailureMessage {
        AccessibleStatusMessage(
          message: String(localized: "操作失败：\(accessFailureMessage)"),
          severity: .error
        )
        .textSelection(.enabled)
      } else if let feedback = AIKeychainActionFeedback(message: actionMessage) {
        AccessibleStatusMessage(
          message: feedback.message,
          severity: feedback.isError ? .error : .success,
          announcesNonUrgentStatus: true
        )
        .textSelection(.enabled)
      }

      HStack(spacing: 6) {
        Image(systemName: storageModeSystemImage)
          .font(.caption)
          .foregroundStyle(Color.accentColor)
        Text(storageModeExplanation)
          .font(.workbenchMetadata)
          .foregroundStyle(.secondary)
      }
      .padding(.top, 4)
    }
    .task(id: navigationRequestID) {
      guard shouldFocusInput else { return }
      isAPIKeyFocused = true
    }
    .confirmationDialog(
      "删除\(config.normalizedDisplayName) API Key？",
      isPresented: $isDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("删除\(config.normalizedDisplayName) API Key", role: .destructive) {
        onDeleteAPIKey()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("删除后，使用当前服务的 AI 写作、对话和批量建议将不可用，直到重新保存 Key。")
    }
  }

  private var storageModeBinding: Binding<AICredentialStorageMode> {
    Binding(
      get: { storageMode },
      set: { mode in
        onChangeStorageMode(mode)
      }
    )
  }

  private var saveButtonTitle: String {
    String(localized: "保存到\(storageModeTitle(storageMode))")
  }

  private func storageModeTitle(_ mode: AICredentialStorageMode) -> String {
    switch mode {
    case .localFile:
      return String(localized: "本地配置文件（默认）")
    case .keychain:
      return String(localized: "系统钥匙串")
    case .session:
      return String(localized: "仅本次会话")
    }
  }

  private var storageModeSystemImage: String {
    switch storageMode {
    case .localFile:
      return "doc.badge.gearshape"
    case .keychain:
      return "lock.shield.fill"
    case .session:
      return "clock.badge.checkmark"
    }
  }

  private var storageModeExplanation: String {
    switch storageMode {
    case .localFile:
      return String(
        localized: "默认保存在此 Mac 的应用支持目录，文件权限限制为仅当前用户可读写（0600）。内容是明文，请勿共享该配置文件。应用不会访问 AI 钥匙串项目。")
    case .keychain:
      return String(localized: "保存到 macOS 系统钥匙串。只有选择此项后，应用才会读取或修改 AI API Key 的钥匙串项目。")
    case .session:
      return String(localized: "只保存在应用内存中，退出 RepoPress Studio 后自动清除，不写配置文件或钥匙串。")
    }
  }

  private var tokenStatusTitle: LocalizedStringKey {
    switch tokenAvailability.accessState {
    case .available:
      return "已保存 API Key"
    case .missing:
      return "未保存 API Key"
    case .accessFailed:
      return "凭据读取失败"
    }
  }

  private var tokenStatusSystemImage: String {
    switch tokenAvailability.accessState {
    case .available:
      return "checkmark.seal"
    case .missing:
      return "key"
    case .accessFailed:
      return "exclamationmark.triangle"
    }
  }

  private var tokenStatusColor: Color {
    switch tokenAvailability.accessState {
    case .available:
      return WorkbenchTheme.success
    case .missing:
      return .secondary
    case .accessFailed:
      return WorkbenchTheme.warning
    }
  }
}

struct AIKeychainActionFeedback: Equatable {
  let message: String
  let isError: Bool

  init?(message: String?) {
    guard let message = message?.trimmedForPublishing.nilIfEmpty else { return nil }
    let lowercasedMessage = message.lowercased()
    guard
      message.contains("API Key")
        || message.contains("API Base URL")
        || lowercasedMessage.contains("keychain")
    else {
      return nil
    }

    self.message = message
    isError =
      message.contains("失败")
      || message.contains("尚未配置")
      || lowercasedMessage.contains("failed")
      || lowercasedMessage.contains("not configured")
      || lowercasedMessage.contains("unavailable")
      || lowercasedMessage.contains("error")
  }
}
