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
  let checkGitTransport: () async -> RepositoryGitTransportCheck
  let checkAccess: () async -> Void
}

struct RepositoryPermissionSettingsView: View {
  let state: RepositoryPermissionSettingsState
  let actions: RepositoryPermissionSettingsActions
  @Binding var isPresented: Bool
  @State private var gitTransportCheck: RepositoryGitTransportCheck?
  @State private var isCheckingGitTransport = false

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

        Section("Git 推送通道") {
          Text("Git push 使用 origin 的系统 SSH key 或 HTTPS 凭据。仓库 API Token 不会自动替代 SSH key。")
            .font(.caption)
            .foregroundStyle(.secondary)

          Button {
            isCheckingGitTransport = true
            Task {
              let check = await actions.checkGitTransport()
              if !Task.isCancelled {
                gitTransportCheck = check
              }
              isCheckingGitTransport = false
            }
          } label: {
            Label(
              isCheckingGitTransport ? "检查远程中" : "只读检查 Git 推送通道",
              systemImage: "arrow.up.right.circle"
            )
          }
          .disabled(isCheckingGitTransport || state.isPublishing)
          .accessibilityLabel("只读检查 Git 推送通道")
          .accessibilityHint("只读取 origin 远程引用，不推送或修改文件，不能验证 push 写入权限")

          if let check = gitTransportCheck {
            Label(
              check.canReadRemote
                ? String(localized: "远程可读取：\(check.remoteName)")
                : String(localized: "无法读取远程：\(check.remoteName)"),
              systemImage: check.canReadRemote ? "arrow.down.circle" : "exclamationmark.triangle"
            )
            .foregroundStyle(check.canReadRemote ? WorkbenchTheme.success : WorkbenchTheme.warning)

            Text(gitRemoteDescription(for: check))
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)

            Text(gitBranchDescription(for: check))
              .font(.caption)
              .foregroundStyle(.secondary)

            Text(check.summary)
              .font(.caption)
              .foregroundStyle(.secondary)

            Text(check.detail)
              .font(.caption)
              .foregroundStyle(.secondary)

            Text(
              check.writePermissionVerified
                ? "Git 写入权限已由独立操作验证。"
                : "此只读检查未验证 Git push 写入权限；首次发布仍会由 Git 返回实际结果。"
            )
            .font(.caption)
            .foregroundStyle(
              check.writePermissionVerified ? WorkbenchTheme.success : WorkbenchTheme.warning)
          } else {
            Text("该诊断只运行 git 只读远程查询：可发现 origin、SSH/HTTPS 传输和远程可读性，但不会推送，也不会将可读性误报为写入权限。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Section("仓库 API Token") {
          Text("此检查使用保存在钥匙串的 GitHub/GitLab API Token；它与 Git push 的 SSH/HTTPS 凭据独立。")
            .font(.caption)
            .foregroundStyle(.secondary)

          Button {
            Task {
              await actions.checkAccess()
            }
          } label: {
            Label(state.isChecking ? "检查 API 权限中" : "检查 API 权限", systemImage: "checkmark.shield")
          }
          .disabled(state.isChecking || state.isPublishing)
          .accessibilityLabel("检查仓库 API Token 权限")
          .accessibilityHint("只读取仓库 API 权限信息，不会创建提交、PR/MR 或推送")

          if let check = state.activeAccessCheck {
            Label(
              apiPermissionTitle(for: check),
              systemImage: check.tokenWriteVerification == .verified ? "lock.open" : "lock"
            )
            .foregroundStyle(apiPermissionColor(for: check))

            if let defaultBranch = check.defaultBranch {
              Text("默认分支：\(defaultBranch)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text(check.permissionSummary)
              .font(.caption)
              .foregroundStyle(.secondary)

            if let tokenScopeSummary = check.tokenScopeSummary?.nilIfEmpty {
              Text(tokenScopeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            Text(check.minimumWritePermission)
              .font(.caption)
              .foregroundStyle(.secondary)

            Text(check.message)
              .font(.caption)
              .foregroundStyle(.secondary)

          } else if state.hasStaleAccessCheck {
            Label(
              "API 权限检查已过期或仓库目标已变化，请重新检查",
              systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(WorkbenchTheme.warning)
          } else {
            Text("保存仓库 API Token 后，可在这里检查当前仓库的 API 访问；这不检查 origin 的 SSH/HTTPS push 权限。")
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

  private func gitTransportDisplayName(_ transport: RepositoryGitTransportKind) -> String {
    switch transport {
    case .ssh:
      return String(localized: "SSH（系统 SSH key/agent）")
    case .https:
      return String(localized: "HTTPS（系统凭据管理）")
    case .local:
      return String(localized: "本地路径")
    case .unknown:
      return String(localized: "未知传输")
    }
  }

  private func gitRemoteDescription(for check: RepositoryGitTransportCheck) -> String {
    let remoteURL = check.sanitizedRemoteURL ?? String(localized: "未读取到远端地址")
    return String(localized: "远程：\(remoteURL)")
  }

  private func gitBranchDescription(for check: RepositoryGitTransportCheck) -> String {
    let branchAvailability =
      check.targetBranchExists == true
      ? String(localized: "（存在）")
      : String(localized: "（未发现或未能读取）")
    return String(
      localized:
        "传输：\(gitTransportDisplayName(check.transport))；目标分支：\(check.targetBranch)\(branchAvailability)"
    )
  }

  private func apiPermissionTitle(for check: RemoteRepositoryAccessCheck) -> String {
    switch check.tokenWriteVerification {
    case .verified:
      return String(localized: "API Token 写入权限已验证：\(check.repositoryName)")
    case .unverified:
      return String(localized: "API Token 写入范围尚未验证：\(check.repositoryName)")
    case .insufficient:
      return String(localized: "API Token 权限不足：\(check.repositoryName)")
    }
  }

  private func apiPermissionColor(for check: RemoteRepositoryAccessCheck) -> Color {
    check.tokenWriteVerification == .verified ? WorkbenchTheme.success : WorkbenchTheme.warning
  }
}
