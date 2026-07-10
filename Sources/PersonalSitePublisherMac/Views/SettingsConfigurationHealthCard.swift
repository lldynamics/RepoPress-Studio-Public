import PublishingWorkbenchCore
import SwiftUI

struct SettingsConfigurationHealthCard: View {
  let profile: SiteProfile
  let repositoryTokenAvailability: KeychainTokenAvailability
  let aiTokenAvailability: KeychainTokenAvailability
  let privacySettings: PrivacyProtectionSettings
  let isProUnlocked: Bool
  let proSource: String

  private var requiredItems: [SettingsConfigurationHealthItem] {
    [
      repositoryItem,
      repositoryTokenItem,
      aiKeyItem,
      defaultRulesItem,
      privacyItem
    ]
  }

  private var allItems: [SettingsConfigurationHealthItem] {
    requiredItems + [proItem]
  }

  private var readyRequiredCount: Int {
    requiredItems.filter(\.isReady).count
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text("配置健康度")
            .font(.headline)
          Text("\(profile.name) · \(readyRequiredCount)/\(requiredItems.count) 项发布配置已就绪")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Label(overallStatusText, systemImage: overallStatusImage)
          .font(.caption.weight(.semibold))
          .foregroundStyle(overallStatusColor)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(overallStatusColor.opacity(0.12), in: Capsule())
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
        ForEach(allItems) { item in
          SettingsConfigurationHealthTile(item: item)
        }
      }
    }
    .padding(12)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("配置健康度")
    .accessibilityValue("\(readyRequiredCount)/\(requiredItems.count) 项发布配置已就绪")
  }

  private var repositoryItem: SettingsConfigurationHealthItem {
    let path = profile.localRepositoryRootPath.trimmedForPublishing
    let isReady = profile.localRepositoryRootURL != nil
    return SettingsConfigurationHealthItem(
      title: "仓库路径",
      detail: isReady ? path : "未选择本地仓库",
      systemImage: "folder",
      state: isReady ? .ready : .warning
    )
  }

  private var repositoryTokenItem: SettingsConfigurationHealthItem {
    SettingsConfigurationHealthItem(
      title: "仓库 Token",
      detail: repositoryTokenAvailability.hasToken ? "已保存，可用于线上发布" : "未保存，线上发布会受限",
      systemImage: "key",
      state: repositoryTokenAvailability.hasToken ? .ready : .warning
    )
  }

  private var aiKeyItem: SettingsConfigurationHealthItem {
    let requiresKey = profile.aiProviderConfig.requiresAPIKey
    let isReady = !requiresKey || aiTokenAvailability.hasToken
    return SettingsConfigurationHealthItem(
      title: "AI Key",
      detail: isReady ? (requiresKey ? "已保存，可生成建议" : "当前配置无需 API Key") : "未保存，AI 功能会受限",
      systemImage: "sparkles",
      state: isReady ? .ready : .warning
    )
  }

  private var defaultRulesItem: SettingsConfigurationHealthItem {
    let hasPublishingPaths = !profile.markdownPathPattern.trimmedForPublishing.isEmpty
      && !profile.imagePathPattern.trimmedForPublishing.isEmpty
      && !profile.publicImagePathPattern.trimmedForPublishing.isEmpty
      && !profile.dateFormat.trimmedForPublishing.isEmpty
    return SettingsConfigurationHealthItem(
      title: "默认规则",
      detail: hasPublishingPaths ? "\(profile.siteKind.displayName) · 路径规则已配置" : "路径或日期规则缺失",
      systemImage: "gearshape.2",
      state: hasPublishingPaths ? .ready : .warning
    )
  }

  private var privacyItem: SettingsConfigurationHealthItem {
    let enabled = [
      privacySettings.requiresUnlockOnLaunch,
      privacySettings.locksWhenInactive,
      privacySettings.masksPrivateContent
    ].filter { $0 }.count
    return SettingsConfigurationHealthItem(
      title: "隐私锁",
      detail: enabled > 0 ? "\(enabled) 项保护已开启" : "未开启隐私保护",
      systemImage: "hand.raised",
      state: enabled > 0 ? .ready : .warning
    )
  }

  private var proItem: SettingsConfigurationHealthItem {
    SettingsConfigurationHealthItem(
      title: "Pro 状态",
      detail: isProUnlocked ? "\(proSource) 权益已生效" : "免费版，可按需升级",
      systemImage: isProUnlocked ? "crown.fill" : "crown",
      state: isProUnlocked ? .ready : .info
    )
  }

  private var overallStatusText: String {
    readyRequiredCount == requiredItems.count ? "已就绪" : "需补配置"
  }

  private var overallStatusImage: String {
    readyRequiredCount == requiredItems.count ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
  }

  private var overallStatusColor: Color {
    readyRequiredCount == requiredItems.count ? .green : .orange
  }
}

private struct SettingsConfigurationHealthTile: View {
  let item: SettingsConfigurationHealthItem

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: item.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
        Text(item.detail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer(minLength: 0)

      Image(systemName: item.state.systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(item.state.color)
        .padding(5)
        .background(item.state.color.opacity(0.12), in: Circle())
        .accessibilityHidden(true)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .combine)
    .accessibilityLabel(item.title)
    .accessibilityValue(item.detail)
  }
}

private struct SettingsConfigurationHealthItem: Identifiable {
  let id = UUID()
  let title: String
  let detail: String
  let systemImage: String
  let state: SettingsConfigurationHealthState

  var isReady: Bool {
    state == .ready
  }
}

private enum SettingsConfigurationHealthState {
  case ready
  case warning
  case info

  var color: Color {
    switch self {
    case .ready:
      return .green
    case .warning:
      return .orange
    case .info:
      return .secondary
    }
  }

  var systemImage: String {
    switch self {
    case .ready:
      return "checkmark.circle.fill"
    case .warning:
      return "exclamationmark.triangle.fill"
    case .info:
      return "info.circle"
    }
  }
}
