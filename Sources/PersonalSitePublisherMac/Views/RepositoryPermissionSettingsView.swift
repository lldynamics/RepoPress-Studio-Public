import PublishingWorkbenchCore
import SwiftUI

struct RepositoryPermissionSettingsState {
  let repositoryProviderDisplayName: String
  let repoOwner: String
  let repoName: String
  let branch: String
  let isChecking: Bool
  let activeAccessCheck: RemoteRepositoryAccessCheck?
  let hasStaleAccessCheck: Bool
  let publishActionMessage: String?
}

struct RepositoryPermissionSettingsActions {
  let checkAccess: () async -> Void
  let copyAccessEvidence: (RemoteRepositoryAccessCheck) -> Void
}

struct RepositoryPermissionSettingsView: View {
  let state: RepositoryPermissionSettingsState
  let actions: RepositoryPermissionSettingsActions
  @Binding var isPresented: Bool

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("仓库权限", systemImage: "lock.shield")
          .font(.headline)

        Spacer()

        Button {
          isPresented = false
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("关闭仓库权限")
        .accessibilityLabel("关闭仓库权限")
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)

      Divider()

      Form {
        Section("当前仓库") {
          Label(state.repositoryProviderDisplayName, systemImage: "server.rack")

          Text("\(state.repoOwner.nilIfEmpty ?? "未填写 owner") / \(state.repoName.nilIfEmpty ?? "未填写 repo")")
            .font(.caption)
            .foregroundStyle(.secondary)

          Text("分支：\(state.branch.nilIfEmpty ?? "main")")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("权限检查") {
          Button {
            Task {
              await actions.checkAccess()
            }
          } label: {
            Label(state.isChecking ? "检查中" : "检查写入权限", systemImage: "checkmark.shield")
          }
          .disabled(state.isChecking)
          .accessibilityLabel("检查仓库写入权限")

          if let check = state.activeAccessCheck {
            Label(
              check.canWrite ? "已确认写入权限：\(check.repositoryName)" : "未确认写入权限：\(check.repositoryName)",
              systemImage: check.canWrite ? "lock.open" : "lock"
            )
            .foregroundStyle(check.canWrite ? .green : .orange)

            if let defaultBranch = check.defaultBranch {
              Text("默认分支：\(defaultBranch)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button {
              actions.copyAccessEvidence(check)
            } label: {
              Label("复制权限证据包", systemImage: "checklist.checked")
            }
          } else if state.hasStaleAccessCheck {
            Label(
              "权限检查来自其它仓库，请重新检查当前仓库",
              systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
          } else {
            Text("保存 Token 后在这里检查当前仓库是否具备写入权限，并复制上架或发布排查需要的证据包。")
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
      .padding()
    }
    .frame(width: 520, height: 420)
  }
}
