import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct SiteMaintenanceContentPerformanceSection: View {
  let report: SiteMaintenanceReport
  let selectedDraft: ArticleDraft?
  @Binding var performancePageViews: String
  @Binding var performanceVisitors: String
  @Binding var performanceSourceName: String
  let openDraft: (UUID) -> Void
  let recordPerformanceSnapshot: (ArticleDraft) -> Void

  var body: some View {
    let summary = report.contentPerformanceSummary

    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Label("内容表现分析", systemImage: "chart.xyaxis.line")
          .font(.headline)
        Spacer()
        Text(summary.hasData ? "已记录 \(summary.trackedArticleCount) 篇" : "未接入分析服务")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }

      Text(summary.hasData
        ? "基于已记录或导入的快照展示内容表现；不会把发布状态当作阅读表现。"
        : "当前工作台还没有外部分析服务；可以先手动记录当前文章的阅读量和访客。")
        .font(.callout)
        .foregroundStyle(.secondary)

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
        MetricTile(title: "阅读量", value: summary.hasData ? "\(summary.totalPageViews)" : "未接入", systemImage: summary.hasData ? "eye" : "eye.slash")
        MetricTile(title: "访客", value: summary.hasData ? "\(summary.totalVisitors)" : "未接入", systemImage: "person.2")
        MetricTile(title: "追踪文章", value: "\(summary.trackedArticleCount)", systemImage: "doc.text.magnifyingglass")
        MetricTile(title: "旧文候选", value: "\(report.staleArticles.count)", systemImage: "clock.badge.exclamationmark")
      }

      if summary.hasData {
        VStack(alignment: .leading, spacing: 8) {
          Text("表现排行")
            .font(.callout.weight(.semibold))

          ForEach(summary.topArticles.prefix(5)) { item in
            Button {
              if let draftID = item.draftID {
                openDraft(draftID)
              }
            } label: {
              HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(item.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                  Text(item.markdownPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
                Spacer()
                Text("\(item.pageViews) 阅读")
                  .font(.caption.weight(.medium))
                Text("\(item.visitors) 访客")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(8)
            .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
          }
        }
      }

      if let draft = selectedDraft {
        VStack(alignment: .leading, spacing: 8) {
          Text("记录当前文章")
            .font(.callout.weight(.semibold))

          HStack(spacing: 8) {
            TextField("阅读量", text: $performancePageViews)
              .textFieldStyle(.roundedBorder)
              .frame(width: 110)
              .accessibilityLabel("当前文章阅读量")
              .accessibilityValue(performancePageViews.nilIfEmpty ?? "未填写")
            TextField("访客", text: $performanceVisitors)
              .textFieldStyle(.roundedBorder)
              .frame(width: 110)
              .accessibilityLabel("当前文章访客数")
              .accessibilityValue(performanceVisitors.nilIfEmpty ?? "未填写")
            TextField("来源", text: $performanceSourceName)
              .textFieldStyle(.roundedBorder)
              .frame(minWidth: 140)
              .accessibilityLabel("内容表现来源")
              .accessibilityValue(performanceSourceName.nilIfEmpty ?? "未填写")
            Button {
              recordPerformanceSnapshot(draft)
            } label: {
              Label("记录表现", systemImage: "plus.circle")
            }
            .disabled(!canRecordPerformanceSnapshot)
            .accessibilityLabel("记录当前文章表现")
          }

          Text(draft.title.nilIfEmpty ?? "未命名文章")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Label("接入分析服务后，可用导入快照替代手动记录，继续复用这里的表现排行和旧文判断。", systemImage: "plugs.connected")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private var canRecordPerformanceSnapshot: Bool {
    (Int(performancePageViews.trimmedForPublishing) ?? -1) >= 0
      && (Int(performanceVisitors.trimmedForPublishing) ?? -1) >= 0
  }
}
