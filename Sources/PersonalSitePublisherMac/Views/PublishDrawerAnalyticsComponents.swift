import PublishingWorkbenchCore
import SwiftUI

struct PublishDrawerAnalyticsCard: View {
  let draft: ArticleDraft
  let settings: SiteAnalyticsSettings?
  let summary: SiteAnalyticsSummary?
  let isLoading: Bool
  let tokenAvailability: KeychainTokenAvailability
  let message: String?
  let refreshAction: () -> Void

  var body: some View {
    PublishDrawerCard(title: "发布后阅读回流", systemImage: "chart.line.uptrend.xyaxis") {
      if let settings, settings.isEnabled {
        HStack(spacing: 8) {
          Label(settings.provider.localizedDisplayName, systemImage: "antenna.radiowaves.left.and.right")
            .font(.caption.weight(.medium))
          Spacer()
          if isLoading {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel("正在刷新阅读数据")
          } else {
            Button(action: refreshAction) {
              Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityIdentifier("publish-drawer-analytics-refresh")
          }
        }

        if let summary {
          HStack(spacing: 8) {
            if let pageviews = summary.pageviews {
              PublishDrawerStat(
                title: "阅读",
                value: "\(pageviews)",
                systemImage: "book.pages",
                color: WorkbenchTheme.success
              )
            }
            if let visitors = summary.visitors {
              PublishDrawerStat(
                title: "访客",
                value: "\(visitors)",
                systemImage: "person.2",
                color: .secondary
              )
            }
            if let visits = summary.visits {
              PublishDrawerStat(
                title: "访问",
                value: "\(visits)",
                systemImage: "arrow.triangle.2.circlepath",
                color: .secondary
              )
            }
            if let requests = summary.requests {
              PublishDrawerStat(
                title: "请求",
                value: "\(requests)",
                systemImage: "network",
                color: .secondary
              )
            }
          }

          if let bounceRate = summary.bounceRate {
            PublishDrawerInfoRow(
              title: "跳出率",
              value: "\(bounceRate.formatted(.number.precision(.fractionLength(1))))%",
              systemImage: "arrow.uturn.left"
            )
          }
          PublishDrawerInfoRow(
            title: "统计时间",
            value: "\(summary.dateRange.start.formatted(date: .abbreviated, time: .omitted))–\(summary.dateRange.end.formatted(date: .abbreviated, time: .omitted))",
            systemImage: "calendar"
          )
          if let pagePath = summary.pagePath {
            PublishDrawerInfoRow(
              title: "文章路径",
              value: pagePath,
              systemImage: "link"
            )
          }
          Text("「\(draft.title)」已按文章公开路径读取页面级数据。")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if !tokenAvailability.hasToken {
          Label(
            tokenAvailability.accessFailureMessage.map { "钥匙串读取失败：\($0)" }
              ?? "还没有可用的只读访问令牌。",
            systemImage: "key"
          )
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
          Text("请在“设置 → 仓库与部署 → 阅读数据”保存令牌，发布后即可在这里刷新表现。")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if settings.configuration == nil {
          Label("统计服务配置尚未完整。", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.warning)
        } else {
          Label("还没有阅读数据快照。", systemImage: "chart.line.uptrend.xyaxis")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let message {
          Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Text("连接 Plausible、Umami 或 Cloudflare Analytics 后，发布抽屉会按当前文章路径回流阅读、访客和访问数据。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Label("尚未启用阅读数据", systemImage: "chart.line.uptrend.xyaxis")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("在“设置 → 仓库与部署 → 阅读数据”启用只读统计。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier("publish-drawer-post-publish-analytics")
  }
}
