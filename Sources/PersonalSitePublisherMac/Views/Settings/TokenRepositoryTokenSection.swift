import PublishingWorkbenchCore
import SwiftUI

struct TokenRepositoryTokenSection: View {
  let repositoryProvider: RepositoryProvider
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

  var body: some View {
    Section("仓库凭据") {
      if repositoryProvider == .github {
        DisclosureGroup(isExpanded: $showsPATGuide) {
          VStack(alignment: .leading, spacing: 6) {
            Text("创建 Token 时请注意勾选 repo (全权控制私有仓库) 与 workflow 权限。")
              .font(.caption)
              .foregroundStyle(.secondary)

            Button {
              NSWorkspace.shared.open(
                URL(
                  string:
                    "https://github.com/settings/tokens/new?scopes=repo,workflow&description=RepoPressMac"
                )!)
            } label: {
              Label("前往 GitHub 打开 Token 创建页", systemImage: "arrow.up.right.square")
                .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
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
          TextField(String(localized: "仓库平台访问令牌（GitHub / GitLab）"), text: repositoryTokenInput)
            .focused($isRepositoryTokenFocused)
            .font(.body.monospaced())
            .accessibilityLabel("仓库访问令牌")
        } else {
          SecureField(String(localized: "仓库平台访问令牌（GitHub / GitLab）"), text: repositoryTokenInput)
            .focused($isRepositoryTokenFocused)
            .accessibilityLabel("仓库访问令牌")
        }

        Button {
          isTokenRevealed.toggle()
        } label: {
          Image(systemName: isTokenRevealed ? "eye.slash" : "eye")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(isTokenRevealed ? "隐藏令牌" : "显示令牌明文")
        .accessibilityLabel(isTokenRevealed ? "隐藏仓库访问令牌" : "显示仓库访问令牌明文")
      }
      .accessibilityLabel("仓库访问令牌")
      .accessibilityHint("仅用于仓库创建、权限检查、提交、PR/MR 和回滚")

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
          withAnimation {
            isJustSaved = true
          }
          Task {
            try? await Task.sleep(for: .seconds(2.5))
            await MainActor.run {
              withAnimation {
                isJustSaved = false
              }
            }
          }
        }
        .workbenchProminentActionStyle()
        .disabled(repositoryTokenInput.wrappedValue.trimmedForPublishing.isEmpty)
        .accessibilityLabel("保存仓库访问令牌")

        if isJustSaved {
          AccessibleStatusMessage(
            message: String(localized: "已保存"), severity: .success,
            announcesNonUrgentStatus: true
          )
          .transition(.opacity)
        } else if !repositoryTokenInput.wrappedValue.trimmedForPublishing.isEmpty {
          Text("待保存修改")
            .font(.caption.weight(.medium))
            .foregroundStyle(WorkbenchTheme.warning)
        }
      }
      .onChange(of: repositoryTokenInput.wrappedValue) { _, newValue in
        if !newValue.trimmedForPublishing.isEmpty {
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
        .accessibilityLabel("刷新访问令牌状态")

        Button("删除", role: .destructive) {
          isDeleteConfirmationPresented = true
        }
        .buttonStyle(.borderless)
        .disabled(!tokenAvailability.hasToken)
        .accessibilityLabel("删除仓库访问令牌")
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
      "删除\(repositoryProvider.localizedDisplayName)仓库访问令牌？",
      isPresented: $isDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("删除\(repositoryProvider.localizedDisplayName)仓库访问令牌", role: .destructive) {
        onDeleteToken()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("删除后，\(repositoryProvider.localizedDisplayName) 的仓库创建、权限检查、线上发布与回滚将不可用，直到重新保存令牌。")
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
