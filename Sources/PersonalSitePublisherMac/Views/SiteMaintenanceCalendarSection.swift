import Foundation
import PublishingWorkbenchCore
import SwiftUI

struct SiteMaintenanceCalendarSection: View {
  let report: SiteMaintenanceReport
  let applySuggestedSchedule: () -> Void
  let openDraft: (UUID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("内容日历")
          .font(.headline)
        Spacer()
        Button {
          applySuggestedSchedule()
        } label: {
          Label("应用建议排期", systemImage: "calendar.badge.plus")
        }
        .disabled(report.calendarScheduleItems.isEmpty)
        Text("\(report.calendarBuckets.count) 个月")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if report.calendarBuckets.isEmpty {
        EmptyStateView(
          title: "还没有内容节奏",
          message: "当前 Profile 没有可统计的文章。",
          systemImage: "calendar"
        )
        .frame(height: 180)
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
          ForEach(report.calendarBuckets.prefix(12)) { bucket in
            VStack(alignment: .leading, spacing: 8) {
              Text(bucket.title)
                .font(.callout.weight(.medium))
              HStack {
                Label("\(bucket.articleCount)", systemImage: "doc.text")
                Label("\(bucket.publishedCount)", systemImage: "checkmark.seal")
                Label("\(bucket.readyCount)", systemImage: "paperplane")
              }
              .font(.caption)
              .foregroundStyle(.secondary)
              Text("公开 \(bucket.publicCount) · 私密 \(bucket.privateCount)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
          }
        }

        MaintenanceCalendarBucketChart(buckets: Array(report.calendarBuckets.prefix(12)))
        maintenanceCalendarGrid
      }

      if !report.calendarInsights.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("内容节奏提示")
            .font(.callout.weight(.semibold))

          ForEach(report.calendarInsights) { insight in
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: insight.systemImage)
                .foregroundStyle(actionPriorityForeground(insight.priority))
                .frame(width: 18)
              VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                  Text(insight.title)
                    .font(.caption.weight(.semibold))
                  Text(insight.priority.localizedDisplayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(actionPriorityForeground(insight.priority))
                  Spacer()
                }
                Text(insight.summary)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
                if !insight.detail.isEmpty {
                  Text(insight.detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                }
              }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
          }
        }
      }

      if !report.calendarScheduleItems.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("待发布排期")
            .font(.callout.weight(.semibold))

          ForEach(report.calendarScheduleItems.prefix(8)) { item in
            Button {
              openDraft(item.draftID)
            } label: {
              HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.systemImage)
                  .foregroundStyle(.secondary)
                  .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                  HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                      .font(.caption.weight(.semibold))
                      .lineLimit(1)
                    Spacer()
                    Text(item.scheduledDate.workbenchShortText)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                  Text(item.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                  Text(item.markdownPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开维护计划文章")
            .accessibilityValue(item.title)
            .padding(10)
            .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
          }
        }
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.subtle, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private var maintenanceCalendarGrid: some View {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = .autoupdatingCurrent
    calendar.timeZone = .autoupdatingCurrent
    let anchorDate = report.calendarScheduleItems.first?.scheduledDate ?? report.generatedAt
    let startOfMonth = calendar.dateInterval(of: .month, for: anchorDate)?.start ?? anchorDate
    let monthTitle = maintenanceMonthTitle(startOfMonth)
    let cells = maintenanceCalendarCells(month: startOfMonth, calendar: calendar)
    let weekdaySymbols = calendar.shortStandaloneWeekdaySymbols
    let firstWeekdayIndex = calendar.firstWeekday - 1
    let orderedWeekdays = Array(weekdaySymbols[firstWeekdayIndex..<weekdaySymbols.count])
      + Array(weekdaySymbols[0..<firstWeekdayIndex])

    return VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Label("发布日历视图", systemImage: "calendar")
          .font(.callout.weight(.semibold))
        Spacer()
        Text(monthTitle)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }

      LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
        ForEach(orderedWeekdays, id: \.self) { weekday in
          Text(weekday)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        }

        ForEach(cells) { cell in
          maintenanceCalendarDayCell(cell)
        }
      }
    }
    .padding(10)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private func maintenanceCalendarDayCell(_ cell: MaintenanceCalendarCell) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(cell.dayText)
          .font(.caption2.weight(cell.isToday ? .bold : .medium))
          .foregroundStyle(cell.isInDisplayedMonth ? .primary : .tertiary)
        Spacer(minLength: 2)
        if !cell.scheduleItems.isEmpty {
          Text("\(cell.scheduleItems.count)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(WorkbenchTheme.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
              WorkbenchTheme.primary.opacity(WorkbenchOpacity.accentBackground),
              in: Capsule()
            )
        }
      }

      ForEach(cell.scheduleItems.prefix(2)) { item in
        Button {
          openDraft(item.draftID)
        } label: {
          Text(item.title)
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(WorkbenchTheme.documentForeground)
        }
        .buttonStyle(.plain)
      }

      if cell.scheduleItems.count > 2 {
        Text("+\(cell.scheduleItems.count - 2)")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)
    }
    .padding(6)
    .frame(minHeight: 62, alignment: .topLeading)
    .background(
      maintenanceCalendarDayBackground(cell),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        .strokeBorder(
          cell.isToday ? WorkbenchTheme.primary.opacity(WorkbenchOpacity.controlBackground) : .clear,
          lineWidth: 1
        )
    }
  }

  private func maintenanceCalendarDayBackground(_ cell: MaintenanceCalendarCell) -> AnyShapeStyle {
    if cell.isToday {
      return AnyShapeStyle(WorkbenchTheme.document.opacity(WorkbenchOpacity.selectionBackground))
    }
    if cell.isInDisplayedMonth {
      return WorkbenchBackgroundStyle.codeBlock
    }
    return WorkbenchBackgroundStyle.subtle
  }

  private func maintenanceCalendarCells(month: Date, calendar: Calendar) -> [MaintenanceCalendarCell] {
    let startOfMonth = calendar.dateInterval(of: .month, for: month)?.start ?? month
    let weekday = calendar.component(.weekday, from: startOfMonth)
    let leadingEmptyDayCount = (weekday - calendar.firstWeekday + 7) % 7
    let today = calendar.startOfDay(for: report.generatedAt)
    let groupedItems = Dictionary(grouping: report.calendarScheduleItems) {
      calendar.startOfDay(for: $0.scheduledDate)
    }

    return (0..<42).compactMap { index in
      guard let date = calendar.date(byAdding: .day, value: index - leadingEmptyDayCount, to: startOfMonth) else {
        return nil
      }
      let day = calendar.component(.day, from: date)
      return MaintenanceCalendarCell(
        date: date,
        dayText: "\(day)",
        isInDisplayedMonth: calendar.isDate(date, equalTo: startOfMonth, toGranularity: .month),
        isToday: calendar.isDate(date, inSameDayAs: today),
        scheduleItems: groupedItems[calendar.startOfDay(for: date), default: []]
      )
    }
  }

  private func maintenanceMonthTitle(_ date: Date) -> String {
    date.formatted(
      .dateTime
        .year()
        .month(.wide)
        .locale(.autoupdatingCurrent)
    )
  }

  private func actionPriorityForeground(_ priority: MaintenanceActionPriority) -> AnyShapeStyle {
    switch priority {
    case .high:
      return AnyShapeStyle(WorkbenchTheme.risk)
    case .medium:
      return AnyShapeStyle(WorkbenchTheme.warning)
    case .low:
      return AnyShapeStyle(.secondary)
    }
  }
}

private struct MaintenanceCalendarCell: Identifiable {
  var date: Date
  var dayText: String
  var isInDisplayedMonth: Bool
  var isToday: Bool
  var scheduleItems: [ContentCalendarScheduleItem]

  var id: Date { date }
}

private struct MaintenanceCalendarBucketChart: View {
  let buckets: [ContentCalendarBucket]

  private var maxArticleCount: Int {
    max(1, buckets.map(\.articleCount).max() ?? 1)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        Label("月度内容分布", systemImage: "chart.bar.xaxis")
          .font(.callout.weight(.semibold))
        Spacer()
        Text("近 \(buckets.count) 个月")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      ForEach(buckets) { bucket in
        HStack(spacing: 10) {
          Text(bucket.title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: 74, alignment: .leading)

          GeometryReader { proxy in
            let width = proxy.size.width * CGFloat(bucket.articleCount) / CGFloat(maxArticleCount)
            RoundedRectangle(cornerRadius: WorkbenchCornerRadius.chartBar)
              .fill(bucket.readyCount > 0 ? WorkbenchTheme.document.opacity(WorkbenchOpacity.badgeBackground) : Color.secondary.opacity(WorkbenchOpacity.chartSecondary))
              .frame(width: max(width, bucket.articleCount == 0 ? 0 : 4))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(height: 9)
          .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.chartBar))

          Text("\(bucket.articleCount)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 28, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(bucket.title)，\(bucket.articleCount) 篇文章，\(bucket.readyCount) 篇待发布")
        .accessibilityValue("文章总数 \(bucket.articleCount)，待发布 \(bucket.readyCount)")
      }

      HStack(spacing: 10) {
        Label("蓝色月份包含待发布文章", systemImage: "paperplane")
        Label("灰色为历史内容沉淀", systemImage: "doc.text")
      }
      .font(.caption2)
      .foregroundStyle(.tertiary)
    }
  }
}
