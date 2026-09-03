import PublishingWorkbenchCore
import SwiftUI

/// A deliberately conservative summary of the credentials involved in publishing.
///
/// The three credentials are independent: a Git remote may use the system SSH
/// agent (or HTTPS credential helper), while repository and deployment tokens are
/// used by their respective APIs.  A saved token is configuration evidence, not
/// proof that a remote accepted a write or that a deployment finished.
struct PublishingCredentialCapabilityPresentation: Equatable {
  enum Tone: Equatable {
    case configured
    case needsAttention
    case neutral
  }

  struct Row: Equatable, Identifiable {
    let id: String
    let title: String
    let source: String
    let detail: String
    let systemImage: String
    let tone: Tone
  }

  let rows: [Row]

  static func make(
    profile: SiteProfile,
    repositoryTokenAvailability: KeychainTokenAvailability,
    deploymentTokenAvailability: KeychainTokenAvailability,
    readiness: DeploymentStatusProviderReadiness
  ) -> Self {
    let repositoryTokenState = tokenConfigurationDetail(
      availability: repositoryTokenAvailability,
      saved: String(localized: "已保存，仍需运行 API 权限检查确认实际范围。"),
      missing: String(localized: "未保存；API 建仓、提交、PR/MR 与回滚不可用。")
    )
    let deploymentTokenState = tokenConfigurationDetail(
      availability: deploymentTokenAvailability,
      saved: String(localized: "已保存；只用于状态/校验 API，不会触发部署。"),
      missing: String(localized: "未保存；需要令牌的部署状态 API 无法校验。")
    )

    let repositoryName = [
      profile.repoOwner.trimmedForPublishing, profile.repoName.trimmedForPublishing,
    ]
    .filter { !$0.isEmpty }
    .joined(separator: "/")
    let transportTarget =
      repositoryName.isEmpty
      ? String(localized: "origin 尚待连接")
      : String(localized: "origin · \(repositoryName)")
    let deploymentConfigurationDetail =
      readiness.isAPIReady
      ? String(localized: "状态校验配置已就绪，但不代表线上部署成功。")
      : String(localized: "状态校验配置尚待补齐。")

    return Self(rows: [
      Row(
        id: "git-transport",
        title: String(localized: "Git 推送通道"),
        source: String(localized: "\(transportTarget)；系统 SSH key 或 HTTPS 凭据"),
        detail: String(
          localized: "仓库 API Token 不会自动用于 SSH push。请在连接诊断中只读检查远程可读性；该检查不会声称已获 push 权限。"),
        systemImage: "arrow.up.right.circle",
        tone: .neutral
      ),
      Row(
        id: "repository-api",
        title: String(localized: "仓库 API Token"),
        source: String(localized: "\(profile.repositoryProvider.localizedDisplayName) API · 系统钥匙串"),
        detail: repositoryTokenState.detail,
        systemImage: "key.horizontal",
        tone: repositoryTokenState.tone
      ),
      Row(
        id: "deployment-api",
        title: String(localized: "部署状态 API Token"),
        source: String(localized: "\(readiness.provider.localizedDisplayName) · 系统钥匙串"),
        detail: String(
          localized: "\(deploymentTokenState.detail) \(deploymentConfigurationDetail)"),
        systemImage: "waveform.path.ecg",
        tone: readiness.isAPIReady && deploymentTokenAvailability.hasToken
          ? .neutral : deploymentTokenState.tone
      ),
    ])
  }

  private static func tokenConfigurationDetail(
    availability: KeychainTokenAvailability,
    saved: String,
    missing: String
  ) -> (detail: String, tone: Tone) {
    if let failure = availability.accessFailureMessage {
      return (String(localized: "钥匙串读取失败：\(failure)。"), .needsAttention)
    }
    // A value in Keychain means only that setup exists.  Reserve visual success
    // for an operation with an observed success result.
    return availability.hasToken ? (saved, .neutral) : (missing, .needsAttention)
  }
}

struct PublishingCredentialCapabilitySection: View {
  let presentation: PublishingCredentialCapabilityPresentation

  var body: some View {
    Section("发布通道与权限") {
      ForEach(presentation.rows) { row in
        HStack(alignment: .top, spacing: WorkbenchSpacing.control) {
          Image(systemName: row.systemImage)
            .foregroundStyle(color(for: row.tone))
            .frame(width: 20)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 3) {
            Text(row.title)
              .font(.body.weight(.medium))
            Text(row.source)
              .font(.caption)
              .foregroundStyle(.secondary)
            Text(row.detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.title)
        .accessibilityValue("\(row.source)。\(row.detail)")
      }
    }
  }

  private func color(for tone: PublishingCredentialCapabilityPresentation.Tone) -> Color {
    switch tone {
    case .configured:
      return .secondary
    case .needsAttention:
      return WorkbenchTheme.warning
    case .neutral:
      return .secondary
    }
  }
}
