import PublishingDomainContracts
import PublishingGitCore
import SwiftUI

struct GitExecutionPolicySection: View {
  @Binding var executionPolicy: RepositoryGitExecutionPolicy?
  let repositoryRootURL: URL?
  @State private var showsTrustConfirmation = false
  @State private var proposedTrustRoot: URL?
  @State private var errorMessage: String?
  @State private var configuredHooksPath: String?

  var body: some View {
    Section("本地 Git 执行权限") {
      Toggle("使用 SSH 签署本地提交", isOn: signingEnabled)
        .accessibilityIdentifier("git-ssh-signing-enabled")
      if policy.sshCommitSigningEnabled {
        TextField(String(localized: "SSH 密钥绝对路径"), text: signingKey)
          .accessibilityLabel("SSH 提交签名密钥路径")
          .accessibilityIdentifier("git-ssh-signing-key")
        Text("填写 SSH 公钥或私钥文件的绝对路径。签名使用系统 ssh-keygen；签名失败会阻止提交。")
          .font(.workbenchBody)
          .foregroundStyle(.workbenchSecondary)
      }

      LabeledContent("仓库 hooks") {
        Text(trustDescription)
          .foregroundStyle(.workbenchSecondary)
      }
      Button("信任此仓库 hooks…") {
        proposedTrustRoot = repositoryRootURL?.standardizedFileURL
          .resolvingSymlinksInPath()
        showsTrustConfirmation = proposedTrustRoot != nil
      }
      .disabled(repositoryRootURL == nil)
      .accessibilityIdentifier("git-trust-hooks")
      if policy.hasTrustedHooks {
        Button("撤销 hooks 信任", role: .destructive) {
          updatePolicy {
            $0.trustedHooksRepositoryPath = nil
            $0.trustedHooksGitDirectoryPath = nil
          }
        }
        .accessibilityIdentifier("git-revoke-hooks-trust")
      }
      if let configuredHooksPath {
        Label(
          String(
            format: String(
              localized:
                "此仓库通过 core.hooksPath 使用“%@”中的 hooks（例如 husky）。RepoPress 只运行标准 .git/hooks 目录，这些 hooks 不会执行；如需在提交时运行，请把对应脚本放入 .git/hooks。"
            ),
            configuredHooksPath),
          systemImage: "exclamationmark.triangle"
        )
        .font(.workbenchBody)
        .foregroundStyle(.workbenchSecondary)
        .accessibilityIdentifier("git-configured-hooks-path")
      }
      Text(
        "仅用于本地整仓提交与合并完成，不用于 GitHub/GitLab API。默认禁用 hooks；信任后仅执行标准 hooks 目录中的提交 hooks 和整仓发布的 pre-push。路径变化须重新确认。"
      )
      .font(.workbenchBody)
      .foregroundStyle(.workbenchSecondary)
    }
    .task(id: repositoryRootURL) {
      guard let repositoryRootURL else {
        configuredHooksPath = nil
        return
      }
      let path = await RepositoryGitExecutionPolicyService().configuredHooksPath(
        rootURL: repositoryRootURL)
      guard !Task.isCancelled else { return }
      configuredHooksPath = path
    }
    .confirmationDialog(
      String(localized: "允许当前仓库执行 hooks？"),
      isPresented: $showsTrustConfirmation,
      titleVisibility: .visible
    ) {
      Button("信任并启用 hooks", role: .destructive) { confirmTrust() }
      Button("取消", role: .cancel) { proposedTrustRoot = nil }
    } message: {
      Text(
        String(
          format: String(localized: "hooks 可以运行仓库提供的程序，并具有当前用户权限。请先审阅标准 hooks 目录中的脚本。仓库：%@"),
          proposedTrustRoot?.path ?? ""))
    }
    .alert(
      String(localized: "Git 执行权限配置失败"),
      isPresented: Binding(
        get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("好") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private var policy: RepositoryGitExecutionPolicy {
    executionPolicy ?? RepositoryGitExecutionPolicy()
  }

  private var signingEnabled: Binding<Bool> {
    Binding(
      get: { policy.sshCommitSigningEnabled },
      set: { value in updatePolicy { $0.sshCommitSigningEnabled = value } }
    )
  }

  private var signingKey: Binding<String> {
    Binding(
      get: { policy.sshSigningKey },
      set: { value in
        guard value.utf8.count <= 4_096,
          !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
          !value.contains("PRIVATE KEY")
        else {
          errorMessage = RepositoryGitExecutionPolicyError.invalidSigningKey.localizedDescription
          return
        }
        updatePolicy { $0.sshSigningKey = value }
      }
    )
  }

  private var trustDescription: String {
    guard policy.hasTrustedHooks else { return String(localized: "未信任") }
    guard let root = repositoryRootURL?.standardizedFileURL.resolvingSymlinksInPath(),
      root.path == policy.trustedHooksRepositoryPath
    else { return String(localized: "路径已变化，信任已失效") }
    return String(localized: "已信任当前仓库")
  }

  private func updatePolicy(_ update: (inout RepositoryGitExecutionPolicy) -> Void) {
    var value = policy
    update(&value)
    executionPolicy = value
  }

  private func confirmTrust() {
    guard let root = proposedTrustRoot,
      repositoryRootURL?.standardizedFileURL.resolvingSymlinksInPath() == root
    else {
      errorMessage = RepositoryGitExecutionPolicyError.trustNoLongerMatches.localizedDescription
      return
    }
    do {
      executionPolicy = try RepositoryGitExecutionPolicyService().trustingHooks(
        at: root, policy: policy
      )
    } catch {
      errorMessage = error.localizedDescription
    }
    proposedTrustRoot = nil
  }
}
