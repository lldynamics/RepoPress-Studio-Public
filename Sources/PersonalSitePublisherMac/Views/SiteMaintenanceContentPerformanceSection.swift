import Foundation
import PublishingWorkbenchCore
import SwiftUI

enum ContentPerformanceImportNotice {
  case importing
  case imported(sourceName: String, imported: Int, skipped: Int, unmatched: Int)
  case unsupportedEncoding
  case missingHeader
  case missingMetrics
  case profileChanged
  case fileTooLarge
  case failure(String)
}

struct SiteMaintenanceContentPerformanceSection: View {
  let report: SiteMaintenanceReport
  let selectedDraft: ArticleDraft?
  @Binding var performancePageViews: String
  @Binding var performanceVisitors: String
  @Binding var performanceSourceName: String
  let openDraft: (UUID) -> Void
  let recordPerformanceSnapshot: (ArticleDraft) -> Void
  let importCSV: () -> Void
  let importNotice: ContentPerformanceImportNotice?

  var body: some View {
    let summary = report.contentPerformanceSummary

    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Label("内容表现分析", systemImage: "chart.xyaxis.line")
          .font(.headline)
        Spacer()
        Button {
          importCSV()
        } label: {
          Label("导入 CSV", systemImage: "square.and.arrow.down")
        }
        .controlSize(.small)
        Text(summary.hasData ? "已记录 \(summary.trackedArticleCount) 篇" : "未接入分析服务")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }

      Text(summary.hasData
        ? "基于已记录或导入的快照展示内容表现；不会把发布状态当作阅读表现。"
        : "当前工作台还没有外部分析服务；可以先手动记录当前文章的阅读量和访客。")
        .font(.callout)
        .foregroundStyle(.secondary)

      if let importNotice {
        importNoticeLabel(importNotice)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

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

      Label("CSV 会替换同一来源的缓存快照；导入后点击刷新报告，继续复用表现排行和旧文判断。", systemImage: "plugs.connected")
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

  @ViewBuilder
  private func importNoticeLabel(_ notice: ContentPerformanceImportNotice) -> some View {
    switch notice {
    case .importing:
      noticeLabel(Text("正在导入 CSV…"), systemImage: "hourglass")
    case let .imported(sourceName, imported, skipped, unmatched):
      if skipped > 0, unmatched > 0 {
        noticeLabel(Text("\(sourceName)：已导入 \(imported) 条内容表现快照，跳过 \(skipped) 行，有 \(unmatched) 行未匹配到现有文章。"), systemImage: "tray.and.arrow.down")
      } else if skipped > 0 {
        noticeLabel(Text("\(sourceName)：已导入 \(imported) 条内容表现快照，跳过 \(skipped) 行。"), systemImage: "tray.and.arrow.down")
      } else if unmatched > 0 {
        noticeLabel(Text("\(sourceName)：已导入 \(imported) 条内容表现快照，有 \(unmatched) 行未匹配到现有文章。"), systemImage: "tray.and.arrow.down")
      } else {
        noticeLabel(Text("\(sourceName)：已导入 \(imported) 条内容表现快照。"), systemImage: "tray.and.arrow.down")
      }
    case .unsupportedEncoding:
      noticeLabel(Text("导入 CSV 失败：CSV 必须是 UTF-8 编码。"), systemImage: "exclamationmark.triangle")
    case .missingHeader:
      noticeLabel(Text("导入 CSV 失败：CSV 缺少表头。"), systemImage: "exclamationmark.triangle")
    case .missingMetrics:
      noticeLabel(Text("导入 CSV 失败：CSV 需要 pageviews/views 和 visitors/users 两列。"), systemImage: "exclamationmark.triangle")
    case .profileChanged:
      noticeLabel(Text("导入 CSV 失败：导入期间站点配置已切换，请重新选择 CSV。"), systemImage: "exclamationmark.triangle")
    case .fileTooLarge:
      noticeLabel(Text("导入 CSV 失败：CSV 文件超过 100 MB，请拆分后分批导入。"), systemImage: "exclamationmark.triangle")
    case let .failure(details):
      noticeLabel(Text("导入 CSV 失败：\(details)"), systemImage: "exclamationmark.triangle")
    }
  }

  private func noticeLabel(_ title: Text, systemImage: String) -> some View {
    Label {
      title
    } icon: {
      Image(systemName: systemImage)
    }
  }
}
