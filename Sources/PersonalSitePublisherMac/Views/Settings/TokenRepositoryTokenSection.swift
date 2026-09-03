import PublishingWorkbenchCore
import SwiftUI

struct TokenRepositoryTokenSection: View {
  let repositoryProvider: RepositoryProvider
  let repositoryBaseURL: String
  let repositoryTokenInput: Binding<String>
  let shouldFocusInput: Bool
  let navigationRequestID: UUID
  let tokenAvailability: KeychainTokenAvailability
  let onSaveToken: () -> Bool
  let onDeleteToken: () -> Void
  let onRefreshTokenState: () -> Void
  @FocusState private var isRepositoryTokenFocused: Bool
  @State private var isDeleteConfirmationPresented = false
  @State private var isTokenRevealed = false
  @State private var showsPATGuide = false
  @State private var isJustSaved = false
  @State private var saveFailureMessage: String?
  @State private var saveFeedbackResetTask: Task<Void, Never>?

  var body: some View {
    Section("仓库 API 凭据") {
      if repositoryProvider == .github {
        DisclosureGroup(isExpanded: $showsPATGuide) {
          VStack(alignment: .leading, spacing: 8) {
            Text("建议使用 fine-grained personal access token，并将仓库访问范围限制为当前仓库。")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("发布内容与创建 PR：Contents: Read and write；Pull requests: Read and write。")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("重新检查 PR 合并条件：Checks: Read-only；Commit statuses: Read-only。")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("Classic token 可使用 repo scope。只有修改 .github/workflows 中的工作流文件时才需要 workflow scope。")
              .font(.caption)
              .foregroundStyle(.secondary)
            if PreviewPromotionPresentation.offersGitHubTokenSettingsLink(
              provider: repositoryProvider,
              repositoryBaseURL: repositoryBaseURL
            ) {
              Link(destination: URL(string: "https://github.com/settings/personal-access-tokens")!)
              {
                Label("打开 GitHub Token 设置", systemImage: "arrow.up.right.square")
                  .font(.caption.weight(.medium))
              }
            }
          }
          .padding(.vertical, 4)
        } label: {
          Label("如何创建 GitHub 个人访问令牌 (PAT)？", systemImage: "questionmark.circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
        }
      }

      HStack(spacing: 8) {
        if isTokenRevealed {
          TextField(String(localized: "仓库 API 访问令牌（GitHub / GitLab）"), text: repositoryTokenInput)
            .focused($isRepositoryTokenFocused)
            .font(.body.monospaced())
            .accessibilityLabel("仓库 API 访问令牌")
        } else {
          SecureField(String(localized: "仓库 API 访问令牌（GitHub / GitLab）"), text: repositoryTokenInput)
            .focused($isRepositoryTokenFocused)
            .accessibilityLabel("仓库 API 访问令牌")
        }

        Button {
          isTokenRevealed.toggle()
        } label: {
          Image(systemName: isTokenRevealed ? "eye.slash" : "eye")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(isTokenRevealed ? "隐藏令牌" : "显示令牌明文")
        .accessibilityLabel(isTokenRevealed ? "隐藏仓库 API 访问令牌" : "显示仓库 API 访问令牌明文")
      }
      .accessibilityLabel("仓库 API 访问令牌")
      .accessibilityHint(
        "用于仓库创建、API 提交、PR/MR、权限检查和回滚；不会替代 origin 的 SSH key 或 HTTPS 凭据，也不会自动用于 SSH push")

      Text(
        "此令牌仅用于仓库 API（建仓、API 提交、PR/MR、权限检查与回滚）。Git push 使用 origin 的系统 SSH key 或 HTTPS 凭据；保存令牌不代表已有写入权限。"
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack(alignment: .center, spacing: 10) {
        Button(String(localized: "保存令牌")) {
          isJustSaved = false
          saveFailureMessage = nil
          guard onSaveToken() else {
            saveFailureMessage = String(
              localized: "保存失败：无法写入系统钥匙串。请检查钥匙串权限后重试；输入内容仍保留。"
            )
            return
          }
          saveFeedbackResetTask?.cancel()
          isJustSaved = true
          saveFeedbackResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            isJustSaved = false
            saveFeedbackResetTask = nil
          }
        }
        .workbenchProminentActionStyle()
        .disabled(repositoryTokenInput.wrappedValue.trimmedForPublishing.isEmpty)
        .accessibilityLabel("保存仓库 API 访问令牌")

        if isJustSaved {
          AccessibleStatusMessage(
            message: String(localized: "已保存"), severity: .success,
            announcesNonUrgentStatus: true
          )
        } else if !repositoryTokenInput.wrappedValue.trimmedForPublishing.isEmpty {
          Text("待保存修改")
            .font(.caption.weight(.medium))
            .foregroundStyle(WorkbenchTheme.warning)
        }
      }
      .onChange(of: repositoryTokenInput.wrappedValue) { _, newValue in
        if !newValue.trimmedForPublishing.isEmpty {
          saveFeedbackResetTask?.cancel()
          saveFeedbackResetTask = nil
          isJustSaved = false
          saveFailureMessage = nil
        }
      }

      HStack {
        Label(repositoryTokenStatusText, systemImage: tokenStatusSystemImage)
          .foregroundStyle(tokenStatusColor)

        Spacer()

        Button("刷新状态") {
          onRefreshTokenState()
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("刷新仓库 API 访问令牌状态")

        Button("删除", role: .destructive) {
          isDeleteConfirmationPresented = true
        }
        .buttonStyle(.borderless)
        .disabled(!tokenAvailability.hasToken)
        .accessibilityLabel("删除仓库 API 访问令牌")
      }

      if let accessFailureMessage = tokenAvailability.accessFailureMessage {
        Text("操作失败：\(accessFailureMessage)")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
          .textSelection(.enabled)
      }
      if let saveFailureMessage {
        AccessibleStatusMessage(message: saveFailureMessage, severity: .error)
          .textSelection(.enabled)
      }
    }
    .task(id: navigationRequestID) {
      guard shouldFocusInput else { return }
      isRepositoryTokenFocused = true
    }
    .confirmationDialog(
      "删除\(repositoryProvider.localizedDisplayName)仓库 API 访问令牌？",
      isPresented: $isDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("删除\(repositoryProvider.localizedDisplayName)仓库 API 访问令牌", role: .destructive) {
        onDeleteToken()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text(
        "删除后，\(repositoryProvider.localizedDisplayName) 的仓库创建、API 权限检查、API 提交、PR/MR 与回滚将不可用，直到重新保存令牌。Git push 的 SSH/HTTPS 系统凭据不受影响。"
      )
    }
  }

  private var repositoryTokenStatusText: String {
    switch tokenAvailability.accessState {
    case .available:
      return String(localized: "已保存仓库访问令牌")
    case .missing:
      return String(localized: "未保存仓库访问令牌")
    case .accessFailed:
      return String(localized: "Keychain 读取失败")
    }
  }

  private var tokenStatusSystemImage: String {
    tokenAvailability.accessState == .accessFailed
      ? "exclamationmark.triangle"
      : (tokenAvailability.hasToken ? "checkmark.seal" : "key")
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
