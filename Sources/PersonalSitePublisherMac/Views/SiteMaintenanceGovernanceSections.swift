import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct SiteMaintenanceTaxonomySection: View {
  let title: String
  let summary: TaxonomyGovernanceSummary
  let systemImage: String

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label(title, systemImage: systemImage)
          .font(.workbenchSectionTitle)
        Spacer()
        Text("缺失 \(summary.missingCount) · 单篇 \(summary.singletonCount)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if summary.entries.isEmpty {
        Label("还没有可复用的\(summary.title)。", systemImage: "info.circle")
          .foregroundStyle(.secondary)
      } else {
        TaxonomyDistributionChart(summary: summary)

        ForEach(summary.entries.prefix(10)) { entry in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.name)
              .font(.callout.weight(.medium))
              .workbenchTruncatedIdentity(entry.name)
            Text("\(entry.count) 篇")
              .font(.caption)
              .foregroundStyle(entry.count == 1 ? WorkbenchTheme.warning : Color.secondary)
            Spacer()
            let draftTitles = entry.draftTitles.prefix(3).joined(separator: " / ")
            Text(draftTitles)
              .font(.caption)
              .foregroundStyle(.secondary)
              .workbenchTruncatedIdentity(draftTitles)
          }
        }

        if !summary.overloadedEntries.isEmpty {
          Label("高频\(summary.title)：\(summary.overloadedEntries.map(\.name).joined(separator: ", "))", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.warning)
        }
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }
}

private struct TaxonomyDistributionChart: View {
  let summary: TaxonomyGovernanceSummary

  private var entries: [TaxonomyGovernanceEntry] {
    Array(summary.entries.prefix(8))
  }

  private var maxCount: Int {
    max(1, entries.map(\.count).max() ?? 1)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label("\(summary.title)分布", systemImage: "chart.bar")
          .font(.callout.weight(.semibold))
        Spacer()
        Text("缺失 \(summary.missingCount) · 单篇 \(summary.singletonCount)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      ForEach(entries) { entry in
        HStack(spacing: 10) {
          Text(entry.name)
            .font(.caption)
            .workbenchTruncatedIdentity(entry.name)
            .frame(width: 96, alignment: .leading)

          GeometryReader { proxy in
            let width = proxy.size.width * CGFloat(entry.count) / CGFloat(maxCount)
            RoundedRectangle(cornerRadius: WorkbenchCornerRadius.chartBar)
              .fill(entry.count == 1 ? WorkbenchTheme.warning.opacity(WorkbenchOpacity.chartEmphasis) : WorkbenchTheme.success.opacity(WorkbenchOpacity.chartPrimary))
              .frame(width: max(width, 4))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(height: 9)
          .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.chartBar))

          Text("\(entry.count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(entry.count == 1 ? WorkbenchTheme.warning : Color.secondary)
            .frame(width: 28, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.name)，\(entry.count) 篇文章")
      }
    }
  }
}

struct SiteMaintenanceStaleArticleSection: View {
  let report: SiteMaintenanceReport
  let openDraft: (UUID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("旧文整理")
          .font(.workbenchSectionTitle)
        Spacer()
        Text("\(report.staleArticles.count) 篇")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if report.staleArticles.isEmpty {
        Label("没有发现需要优先复查的旧文。", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      } else {
        ForEach(report.staleArticles.prefix(8)) { item in
          Button {
            openDraft(item.draftID)
          } label: {
            VStack(alignment: .leading, spacing: 6) {
              HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                  .font(.callout.weight(.medium))
                  .workbenchTruncatedIdentity(item.title)
                Spacer()
                Text("\(item.daysSinceUpdate) 天未更新")
                  .font(.caption)
                  .foregroundStyle(WorkbenchTheme.warning)
              }
              Text(item.markdownPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .workbenchTruncatedIdentity(item.markdownPath)
              Text(item.reasons.joined(separator: "；"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("打开旧文整理文章")
          .accessibilityValue(item.title)
          .padding(10)
          .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
        }
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }
}

struct SiteMaintenanceRelationSuggestionSection: View {
  let report: SiteMaintenanceReport
  let openDraft: (UUID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("文章关系")
          .font(.workbenchSectionTitle)
        Spacer()
        Text("\(report.relationSuggestions.count) 项")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if report.relationSuggestions.isEmpty {
        Label("没有发现明显的内链补充机会。", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      } else {
        ForEach(report.relationSuggestions.prefix(12)) { item in
          Button {
            openDraft(item.sourceDraftID)
          } label: {
            VStack(alignment: .leading, spacing: 6) {
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.sourceTitle)
                  .font(.callout.weight(.medium))
                  .workbenchTruncatedIdentity(item.sourceTitle)
                Image(systemName: "arrow.right")
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                Text(item.targetTitle)
                  .font(.callout)
                  .workbenchTruncatedIdentity(item.targetTitle)
                Spacer()
              }
              Text(item.targetPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .workbenchTruncatedIdentity(item.targetPath)
              Text(item.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("打开链接建议来源文章")
          .accessibilityValue(String(localized: "\(item.sourceTitle) 到 \(item.targetTitle)"))
          .padding(10)
          .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
        }
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }
}

struct SiteMaintenanceLinkAuditSection: View {
  let report: SiteMaintenanceReport
  let openDraft: (UUID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("链接审计")
          .font(.workbenchSectionTitle)
        Spacer()
        Text("\(report.linkAuditItems.count) 项")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if report.linkAuditItems.isEmpty {
        Label("当前文章链接没有发现明显治理项。", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      } else {
        ForEach(report.linkAuditItems.prefix(12)) { item in
          Button {
            openDraft(item.draftID)
          } label: {
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: item.severity.systemImage)
                .foregroundStyle(linkSeverityForeground(item.severity))
                .frame(width: 16)
              VStack(alignment: .leading, spacing: 4) {
                Text(item.draftTitle)
                  .font(.callout.weight(.medium))
                  .workbenchTruncatedIdentity(item.draftTitle)
                Text(item.target)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .workbenchTruncatedIdentity(item.target)
                Text(item.message)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
                if let statusCode = item.statusCode {
                  Text("HTTP \(statusCode)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                }
                if let finalTarget = item.finalTarget,
                  finalTarget != item.target
                {
                  Text("最终地址：\(finalTarget)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .workbenchTruncatedIdentity(finalTarget)
                }
              }
              Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("打开链接审计文章")
          .accessibilityValue(item.draftTitle)
        }
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }
}

struct SiteMaintenanceOperationLogSection: View {
  let report: SiteMaintenanceReport

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("操作日志")
          .font(.workbenchSectionTitle)
        Spacer()
        Text("\(report.operationLogEntries.count) 条")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if report.operationLogEntries.isEmpty {
        Label("还没有发布或维护操作记录。", systemImage: "list.bullet.clipboard")
          .foregroundStyle(.secondary)
      } else {
        ForEach(report.operationLogEntries) { entry in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: entry.systemImage)
              .foregroundStyle(.secondary)
              .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
              Text(entry.title)
                .font(.callout.weight(.medium))
                .workbenchTruncatedIdentity(entry.title)
              Text(entry.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Spacer()
            Text(entry.createdAt.workbenchShortText)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }
}

private func linkSeverityForeground(_ severity: SiteLinkAuditSeverity) -> AnyShapeStyle {
  switch severity {
  case .info:
    return AnyShapeStyle(.secondary)
  case .warning:
    return AnyShapeStyle(WorkbenchTheme.warning)
  case .error:
    return AnyShapeStyle(WorkbenchTheme.risk)
  }
}
