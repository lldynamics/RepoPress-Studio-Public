import PublishingWorkbenchCore
import SwiftUI

struct RepositoryPermissionSettingsState {
  let repositoryProviderDisplayName: String
  let repoOwner: String
  let repoName: String
  let branch: String
  let isChecking: Bool
  let isPublishing: Bool
  let activeAccessCheck: RemoteRepositoryAccessCheck?
  let hasStaleAccessCheck: Bool
  let publishActionMessage: String?
}

struct RepositoryPermissionSettingsActions {
  let checkAccess: () async -> Void
}

struct RepositoryPermissionSettingsView: View {
  let state: RepositoryPermissionSettingsState
  let actions: RepositoryPermissionSettingsActions
  @Binding var isPresented: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("仓库连接诊断", systemImage: "lock.shield")
          .font(.headline)

        Spacer()

        Button {
          isPresented = false
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("关闭仓库连接诊断")
        .accessibilityLabel("关闭仓库连接诊断")
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)

      Divider()

      Form {
        Section("当前仓库") {
          Label(state.repositoryProviderDisplayName, systemImage: "server.rack")

          Text(
            "\(state.repoOwner.nilIfEmpty ?? "未填写 owner") / \(state.repoName.nilIfEmpty ?? "未填写 repo")"
          )
          .font(.caption)
          .foregroundStyle(.secondary)

          Text("分支：\(state.branch.nilIfEmpty ?? "main")")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("连接诊断") {
          Button {
            Task {
              await actions.checkAccess()
            }
          } label: {
            Label(state.isChecking ? "验证中" : "重新验证连接", systemImage: "checkmark.shield")
          }
          .disabled(state.isChecking || state.isPublishing)
          .accessibilityLabel("重新验证仓库连接")

          if let check = state.activeAccessCheck {
            Label(
              check.canWrite
                ? "检测到仓库写入角色：\(check.repositoryName)" : "未检测到仓库写入角色：\(check.repositoryName)",
              systemImage: check.canWrite ? "lock.open" : "lock"
            )
            .foregroundStyle(check.canWrite ? WorkbenchTheme.success : WorkbenchTheme.warning)

            if let defaultBranch = check.defaultBranch {
              Text("默认分支：\(defaultBranch)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

          } else if state.hasStaleAccessCheck {
            Label(
              "连接诊断已过期或仓库目标已变化，请重新验证",
              systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(WorkbenchTheme.warning)
          } else {
            Text("保存访问令牌后，可在这里诊断当前仓库连接并重新验证写入能力。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if let message = state.publishActionMessage {
          Section("最近结果") {
            Text(message)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)
      .padding(WorkbenchSpacing.content)
    }
    .workbenchSheetSize(.compact)
  }
}
