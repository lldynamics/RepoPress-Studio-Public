import PublishingWorkbenchCore
import SwiftUI

struct TokenConnectionStatusPresentation: Equatable {
  enum Tone: Equatable {
    case success
    case warning
    case neutral
  }

  let title: String
  let detail: String
  let systemImage: String
  let tone: Tone

  static func repository(
    profile: SiteProfile,
    tokenAvailability: KeychainTokenAvailability
  ) -> Self {
    let missingConnectionValues = [
      profile.localRepositoryRootPath.trimmedForPublishing.isEmpty
        ? String(localized: "本地仓库") : nil,
      profile.repoOwner.trimmedForPublishing.isEmpty
        ? String(localized: "所有者") : nil,
      profile.repoName.trimmedForPublishing.isEmpty
        ? String(localized: "远程仓库") : nil,
      profile.branch.trimmedForPublishing.isEmpty
        ? String(localized: "分支") : nil,
    ].compactMap { $0 }

    let tokenDetail =
      tokenAvailability.accessFailureMessage == nil
      ? (tokenAvailability.hasToken
        ? String(localized: "仓库令牌已保存")
        : String(localized: "仓库令牌未保存"))
      : String(localized: "钥匙串读取失败")

    if missingConnectionValues.isEmpty {
      return Self(
        title: String(localized: "仓库目标已填写"),
        detail: String(
          localized:
            "\(profile.repositoryProvider.localizedDisplayName) · \(tokenDetail)。这仅表示配置存在；请在页面底部运行权限检查确认 API 实际访问。Git push 使用 origin 的 SSH/HTTPS 系统凭据，不会自动使用此令牌。"
        ),
        systemImage: tokenAvailability.hasToken ? "shippingbox.fill" : "shippingbox",
        // Saved configuration is not evidence that the API token or Git
        // transport can write. Only an explicit permission check may use a
        // success state for that claim.
        tone: .neutral
      )
    }

    return Self(
      title: String(localized: "仓库连接待补齐"),
      detail: String(
        localized:
          "还需填写：\(missingConnectionValues.formatted(.list(type: .and)))；\(tokenDetail)。"
      ),
      systemImage: "exclamationmark.triangle",
      tone: .warning
    )
  }

  static func deployment(
    readiness: DeploymentStatusProviderReadiness,
    tokenAvailability: KeychainTokenAvailability
  ) -> Self {
    let tokenDetail =
      tokenAvailability.accessFailureMessage == nil
      ? (tokenAvailability.hasToken
        ? String(localized: "部署令牌已保存")
        : String(localized: "部署令牌未保存"))
      : String(localized: "钥匙串读取失败")

    return Self(
      title: readiness.isAPIReady ? String(localized: "部署状态校验已配置") : readiness.statusTitle,
      detail: String(
        localized:
          "\(readiness.provider.localizedDisplayName) · \(tokenDetail)。\(readiness.nextStep) 这仅表示状态校验配置，不代表线上部署成功，也不会自动触发部署。"
      ),
      systemImage: readiness.isAPIReady
        ? "checkmark.seal"
        : readiness.canCheckAnyStatus ? "exclamationmark.triangle" : "xmark.octagon",
      tone: readiness.isAPIReady ? .neutral : .warning
    )
  }
}

struct TokenConnectionStatusSummary: View {
  let presentation: TokenConnectionStatusPresentation

  var body: some View {
    Section {
      HStack(alignment: .top, spacing: WorkbenchSpacing.control) {
        Image(systemName: presentation.systemImage)
          .font(.title3)
          .foregroundStyle(statusColor)
          .frame(width: 24)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 3) {
          Text(presentation.title)
            .font(.headline)
          Text(presentation.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(presentation.title)
      .accessibilityValue(presentation.detail)
    }
  }

  private var statusColor: Color {
    switch presentation.tone {
    case .success:
      return WorkbenchTheme.success
    case .warning:
      return WorkbenchTheme.warning
    case .neutral:
      return .secondary
    }
  }
}
