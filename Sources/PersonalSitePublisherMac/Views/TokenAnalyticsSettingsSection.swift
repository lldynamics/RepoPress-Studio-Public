import PublishingWorkbenchCore
import SwiftUI

struct TokenAnalyticsSettingsSection: View {
  let settings: Binding<SiteAnalyticsSettings>
  @Binding var tokenInput: String
  let tokenAvailability: KeychainTokenAvailability
  let onSaveToken: () -> Void
  let onDeleteToken: () -> Void
  let onRefreshTokenState: () -> Void

  var body: some View {
    Section("阅读数据回流") {
      Toggle("启用只读阅读数据", isOn: settings.isEnabled)
        .accessibilityLabel("启用只读阅读数据回流")
        .accessibilityValue(settings.wrappedValue.isEnabled ? "开启" : "关闭")

      if settings.wrappedValue.isEnabled {
        Picker("统计服务", selection: settings.provider) {
          ForEach(SiteAnalyticsProvider.allCases, id: \.self) { provider in
            Text(provider.localizedDisplayName).tag(provider)
          }
        }
        .accessibilityLabel("阅读数据统计服务")
        .accessibilityValue(settings.wrappedValue.provider.localizedDisplayName)

        if settings.wrappedValue.requiresBaseURL {
          TextField("统计接口 URL", text: settings.baseURL)
            .textContentType(.URL)
            .accessibilityLabel("统计接口 URL")
            .accessibilityValue(settings.wrappedValue.baseURL.nilIfEmpty ?? "未填写")
        } else {
          Text("Cloudflare Analytics 使用官方 GraphQL 只读接口。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        TextField(settings.wrappedValue.identifierLabel, text: settings.siteID)
          .accessibilityLabel(settings.wrappedValue.identifierLabel)
          .accessibilityValue(settings.wrappedValue.siteID.nilIfEmpty ?? "未填写")

        Picker("统计时间窗", selection: settings.dateRangeDays) {
          Text("最近 7 天").tag(7)
          Text("最近 14 天").tag(14)
          Text("最近 28 天").tag(28)
          Text("最近 90 天").tag(90)
        }
        .accessibilityLabel("统计时间窗")
        .accessibilityValue("最近 \(settings.wrappedValue.normalizedDateRangeDays) 天")

        SecureField("只读访问令牌", text: $tokenInput)
          .textContentType(.password)
          .accessibilityLabel("阅读数据只读访问令牌")

        HStack(spacing: 8) {
          Button("保存令牌", action: onSaveToken)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

          Button("删除令牌", action: onDeleteToken)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!tokenAvailability.hasToken)

          Button(action: onRefreshTokenState) {
            Label("刷新状态", systemImage: "arrow.clockwise")
          }
          .buttonStyle(.borderless)
          .controlSize(.small)
        }

        Label(
          tokenAvailability.hasToken
            ? "只读令牌已保存在钥匙串"
            : tokenAvailability.accessFailureMessage.map { "钥匙串读取失败：\($0)" }
              ?? "尚未保存只读令牌",
          systemImage: tokenAvailability.hasToken ? "checkmark.circle" : "info.circle"
        )
        .font(.caption)
        .foregroundStyle(tokenAvailability.hasToken ? WorkbenchTheme.success : WorkbenchTheme.warning)
      }

      Text("发布抽屉会按当前文章的公开 URL 路径读取页面级数据；不会写入统计服务、上传内容或把令牌保存到工作区文件。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
