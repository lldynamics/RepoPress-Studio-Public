import PublishingWorkbenchCore
import SwiftUI

struct TokenRepositoryTokenSection: View {
  let repositoryProviderName: String
  let repositoryTokenInput: Binding<String>
  let shouldFocusInput: Bool
  let navigationRequestID: UUID
  let hasRepositoryToken: Bool
  let onSaveToken: () -> Void
  let onDeleteToken: () -> Void
  let onRefreshTokenState: () -> Void
  let onOpenRepositoryPermission: () -> Void
  @FocusState private var isRepositoryTokenFocused: Bool
  @State private var isDeleteConfirmationPresented = false

  var body: some View {
    Section("仓库凭据") {
      SecureField(String(localized: "仓库平台访问令牌（GitHub / GitLab）"), text: repositoryTokenInput)
        .focused($isRepositoryTokenFocused)
        .accessibilityLabel("仓库访问令牌")
        .accessibilityHint("仅用于仓库创建、权限检查、提交、PR/MR 和回滚")

      HStack {
        Button(String(localized: "保存令牌")) {
          onSaveToken()
        }
        .workbenchProminentActionStyle()
        .disabled(repositoryTokenInput.wrappedValue.trimmedForPublishing.isEmpty)
        .accessibilityLabel("保存仓库访问令牌")

        Button {
          onOpenRepositoryPermission()
        } label: {
          Label("检查仓库权限", systemImage: "lock.shield")
        }
        .accessibilityLabel("打开仓库权限设置")
      }

      HStack {
        Label(repositoryTokenStatusText, systemImage: hasRepositoryToken ? "checkmark.seal" : "key")
          .foregroundStyle(hasRepositoryToken ? WorkbenchTheme.success : Color.secondary)

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
        .disabled(!hasRepositoryToken)
        .accessibilityLabel("删除仓库访问令牌")
      }
    }
    .task(id: navigationRequestID) {
      guard shouldFocusInput else { return }
      isRepositoryTokenFocused = true
    }
    .confirmationDialog(
      "删除\(repositoryProviderName)仓库访问令牌？",
      isPresented: $isDeleteConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("删除\(repositoryProviderName)仓库访问令牌", role: .destructive) {
        onDeleteToken()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("删除后，\(repositoryProviderName) 的仓库创建、权限检查、线上发布与回滚将不可用，直到重新保存令牌。")
    }
  }

  private var repositoryTokenStatusText: String {
    hasRepositoryToken
      ? String(localized: "已保存仓库访问令牌")
      : String(localized: "未保存仓库访问令牌")
  }
}
