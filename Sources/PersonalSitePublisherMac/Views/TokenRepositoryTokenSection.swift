import SwiftUI

struct TokenRepositoryTokenSection: View {
  let repositoryTokenInput: Binding<String>
  let hasRepositoryToken: Bool
  let onSaveToken: () -> Void
  let onDeleteToken: () -> Void
  let onRefreshTokenState: () -> Void
  let onOpenRepositoryPermission: () -> Void

  var body: some View {
    Section("仓库访问 Token") {
      SecureField("\u{7AD9}\u{5E93} Provider Token（GitHub / GitLab）", text: repositoryTokenInput)
        .accessibilityLabel("仓库访问 Token")
        .accessibilityHint("仅用于仓库创建、权限检查、提交、PR/MR 和回滚")

      HStack {
        Button("保存 Token") {
          onSaveToken()
        }
        .accessibilityLabel("保存仓库访问 Token")

        Button("删除") {
          onDeleteToken()
        }
        .accessibilityLabel("删除仓库访问 Token")

        Button("刷新状态") {
          onRefreshTokenState()
        }
        .accessibilityLabel("刷新 Token 状态")
      }

      Label(hasRepositoryToken ? "已保存仓库 Token" : "未保存仓库 Token", systemImage: hasRepositoryToken ? "checkmark.seal" : "key")
        .foregroundStyle(hasRepositoryToken ? .green : .secondary)

      Button {
        onOpenRepositoryPermission()
      } label: {
        Label("打开仓库权限", systemImage: "lock.shield")
      }
      .accessibilityLabel("打开仓库权限设置")
    }
  }
}
