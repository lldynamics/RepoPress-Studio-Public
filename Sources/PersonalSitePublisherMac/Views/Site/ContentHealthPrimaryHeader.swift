import SwiftUI

struct ContentHealthPrimaryHeader: View {
  let snapshot: ContentHealthSnapshot
  let summary: ContentHealthSiteSummary
  let isRefreshing: Bool
  let showsFilters: Bool
  @Binding var contextFilter: ContentHealthContextFilter
  @Binding var severity: ContentHealthSeverityFilter
  @Binding var source: ContentHealthSourceFilter
  @Binding var aiFix: ContentHealthAIFixFilter
  @Binding var grouping: ContentHealthArticleGrouping
  @Binding var search: String
  let recheck: () -> Void
  let recheckExternalLinks: () -> Void
  @Environment(\.workbenchAccentColor) private var accentColor

  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.content) {
      HStack(alignment: .top, spacing: WorkbenchSpacing.card) {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.tight) {
          Text("站点检查")
            .font(.workbenchPageTitle)
          Text(
            String(
              localized:
                "上次扫描 \(snapshot.generatedAt.workbenchShortText) · \(snapshot.profileName) · \(snapshot.contentHealthSummaries.count) 篇文章"
            )
          )
          .font(.workbenchPageSubtitle)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          if isRefreshing {
            Text("正在更新")
              .font(.workbenchMetadata)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 0)
        HStack(spacing: WorkbenchSpacing.tight) {
          Button(action: recheck) {
            Label("重新检查", systemImage: "arrow.clockwise")
          }
          .accessibilityIdentifier("content-health-recheck")
          Menu {
            Button("强制重新核验外部链接", action: recheckExternalLinks)
          } label: {
            Image(systemName: "chevron.down")
              .font(.system(size: WorkbenchIconSize.indicator))
          }
          .menuIndicator(.hidden)
          .accessibilityLabel("重新检查选项")
          .accessibilityIdentifier("content-health-recheck-options")
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(isRefreshing)
      }

      HStack(spacing: WorkbenchSpacing.control) {
        countCard("错误", value: summary.errorCount, section: .errors, filter: .errors)
        countCard("警告", value: summary.warningCount, section: .warnings, filter: .warnings)
        countCard(
          "维护", value: summary.maintenanceCount, section: .maintenance, filter: .maintenance)
        metric(
          "已通过", value: summary.passingDraftCount, systemImage: "checkmark.circle",
          color: WorkbenchTheme.success, isSelected: false
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("已通过，文章统计")
        .accessibilityValue("\(summary.passingDraftCount)")
        .accessibilityIdentifier("content-health-count-passed")
        .help(String(localized: "通过是当前站点没有错误或警告的文章统计，不能作为筛选条件。"))
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel("内容健康摘要")

      if showsFilters {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: WorkbenchSpacing.control) {
            searchField
            filterControls
          }
          VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
            searchField
            ViewThatFits(in: .horizontal) {
              HStack(spacing: WorkbenchSpacing.control) { filterControls }
              VStack(alignment: .leading, spacing: WorkbenchSpacing.control) { filterControls }
            }
          }
        }
      }
    }
  }

  private var searchField: some View {
    HStack(spacing: WorkbenchSpacing.icon) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField("筛选问题或文章", text: $search)
        .textFieldStyle(.plain)
        .accessibilityLabel("筛选问题或文章")
        .accessibilityIdentifier("content-health-search")
    }
    .padding(WorkbenchSpacing.control)
    .frame(minWidth: 120, maxWidth: .infinity)
    .background(
      WorkbenchBackgroundStyle.control,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  @ViewBuilder
  private var filterControls: some View {
    Picker(
      "来源",
      selection: Binding(
        get: { source },
        set: { value in
          source = value
          contextFilter = .overview
          if value == .maintenance { severity = .all }
          if value == .site { aiFix = .all }
        })
    ) {
      ForEach(ContentHealthSourceFilter.allCases) { Text($0.title).tag($0) }
    }
    .pickerStyle(.menu)
    .fixedSize()
    .accessibilityLabel("问题来源筛选")
    .accessibilityIdentifier("content-health-source-filter")

    if source != .site {
      Toggle(
        "可 AI 修复",
        isOn: Binding(
          get: { aiFix == .fixable },
          set: { enabled in
            aiFix = enabled ? .fixable : .all
            contextFilter = .overview
          })
      )
      .toggleStyle(.checkbox)
      .fixedSize()
      .accessibilityLabel("AI 修复能力筛选")
      .accessibilityIdentifier("content-health-ai-filter")
    }

    if source.includesArticles {
      Picker("分组方式", selection: $grouping) {
        ForEach(ContentHealthArticleGrouping.visibleCases) { option in
          Text(option == .actionQueue ? String(localized: "按问题分组") : option.title).tag(option)
        }
      }
      .pickerStyle(.menu)
      .fixedSize()
      .accessibilityLabel("文章分组方式")
      .accessibilityIdentifier("content-health-grouping")
    }
  }

  private func countCard(
    _ title: LocalizedStringKey, value: Int,
    section: ContentHealthIssueSection, filter: ContentHealthCountFilter
  ) -> some View {
    let isSelected = filter.isSelected(severity: severity, source: source)
    return Button {
      let next = filter.toggled(severity: severity, source: source)
      contextFilter = .overview
      source = next.source
      severity = next.severity
      aiFix = .all
    } label: {
      metric(
        title, value: value, systemImage: section.systemImage, color: section.color,
        isSelected: isSelected)
    }
    .buttonStyle(WorkbenchFocusRingButtonStyle(cornerRadius: WorkbenchCornerRadius.card))
    .accessibilityLabel(title)
    .accessibilityValue(isSelected ? "\(value)，已筛选" : "\(value)，未筛选")
    .accessibilityHint("点击切换筛选，再次点击取消")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("content-health-count-\(filter.rawValue)")
  }

  private func metric(
    _ title: LocalizedStringKey, value: Int, systemImage: String, color: Color, isSelected: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.tight) {
      Label(title, systemImage: systemImage)
        .font(.workbenchMetadata)
        .foregroundStyle(color)
        .lineLimit(1)
      Text("\(value)")
        .font(.workbenchMetricValue)
        .monospacedDigit()
        .foregroundStyle(.primary)
    }
    .padding(WorkbenchSpacing.card)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected
        ? AnyShapeStyle(accentColor.opacity(WorkbenchOpacity.selectionBackground))
        : WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .strokeBorder(
          isSelected ? accentColor : Color.primary.opacity(WorkbenchOpacity.noticeBackground),
          lineWidth: 1)
    }
  }
}

extension ContentHealthIssueSection {
  var color: Color {
    switch self {
    case .errors: WorkbenchTheme.risk
    case .warnings: WorkbenchTheme.warning
    case .maintenance: WorkbenchTheme.info
    }
  }
}
