import Foundation
import SwiftUI
import PublishingWorkbenchCore

extension RSSArticleList {
  var selectedScope: RSSArticleScope {
    presentation.selectedScope ?? .all
  }

  var isSingleFeedScope: Bool {
    if case .feed = selectedScope { return true }
    return false
  }

  var selectedFeed: RSSFeed? {
    guard case .feed(let feedID) = selectedScope else { return nil }
    return store.feeds.first { $0.id == feedID }
  }

  var scopeIsRefreshing: Bool {
    if let selectedFeed {
      return store.refreshingFeedIDs.contains(selectedFeed.id)
    }
    return store.isRefreshing
  }

  var hasActiveFilters: Bool {
    !presentation.debouncedSearchText.trimmedForPublishing.isEmpty
      || presentation.unreadOnly
      || presentation.selectedSourceID != nil
      || presentation.selectedAuthor != nil
      || presentation.selectedTag != nil
      || presentation.dateRange != .all
  }

  var activeFilterCount: Int {
    var count = 0
    if !presentation.debouncedSearchText.trimmedForPublishing.isEmpty { count += 1 }
    if presentation.unreadOnly { count += 1 }
    if presentation.selectedSourceID != nil { count += 1 }
    if presentation.selectedAuthor != nil { count += 1 }
    if presentation.selectedTag != nil { count += 1 }
    if presentation.dateRange != .all { count += 1 }
    return count
  }

  var articleFilterSortAccessibilityValue: String {
    var components: [String] = []
    if activeFilterCount == 0 {
      components.append("未启用筛选")
    } else {
      components.append("启用 \(activeFilterCount) 项筛选")
    }
    components.append("排序 \(presentation.sortOrder.title)")
    components.append(presentation.groupsByDate ? "按日期分组" : "不按日期分组")
    return components.joined(separator: "，")
  }

  var advancedFilterCount: Int {
    var count = 0
    if presentation.selectedSourceID != nil { count += 1 }
    if presentation.selectedAuthor != nil { count += 1 }
    if presentation.selectedTag != nil { count += 1 }
    return count
  }

  @ViewBuilder
  func filterControls(
    availableSources: [RSSFeed],
    availableAuthors: [String],
    availableTags: [String]
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      wideFilterControls(
        availableSources: availableSources,
        availableAuthors: availableAuthors,
        availableTags: availableTags
      )
      compactFilterControls(
        availableSources: availableSources,
        availableAuthors: availableAuthors,
        availableTags: availableTags
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("文章筛选与排序")
    .accessibilityValue(articleFilterSortAccessibilityValue)
    .accessibilityIdentifier("rss-article-filter-sort")
  }

  func wideFilterControls(
    availableSources: [RSSFeed],
    availableAuthors: [String],
    availableTags: [String]
  ) -> some View {
    HStack(alignment: .center, spacing: 10) {
      Toggle("只看未读", isOn: $presentation.unreadOnly)
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier("rss-unread-filter")

      Picker("日期", selection: $presentation.dateRange) {
        ForEach(RSSArticleDateRange.allCases) { range in
          Text(range.title).tag(range)
        }
      }
      .pickerStyle(.menu)
      .controlSize(.small)
      .accessibilityIdentifier("rss-date-filter")

      Picker("排序", selection: $presentation.sortOrder) {
        ForEach(RSSArticleSortOrder.allCases) { order in
          Text(order.title).tag(order)
        }
      }
      .pickerStyle(.menu)
      .controlSize(.small)
      .accessibilityIdentifier("rss-sort-picker")

      moreFilterMenu(
        label: advancedFilterCount > 0 ? "更多 \(advancedFilterCount)" : "更多",
        systemImage: advancedFilterCount > 0
          ? "line.3.horizontal.decrease.circle.fill"
          : "line.3.horizontal.decrease.circle",
        includesDate: false,
        availableSources: availableSources,
        availableAuthors: availableAuthors,
        availableTags: availableTags
      )

      if activeFilterCount > 0 {
        Text("已启用 \(activeFilterCount)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize()
      }

      clearFiltersButton(showTitle: true)
      Spacer(minLength: 0)
    }
  }

  func compactFilterControls(
    availableSources: [RSSFeed],
    availableAuthors: [String],
    availableTags: [String]
  ) -> some View {
    HStack(alignment: .center, spacing: 8) {
      Toggle(isOn: $presentation.unreadOnly) {
        Image(systemName: presentation.unreadOnly ? "envelope.badge" : "envelope")
      }
      .toggleStyle(.checkbox)
      .controlSize(.small)
      .help("只看未读")
      .accessibilityLabel("只看未读")
      .accessibilityValue(presentation.unreadOnly ? "已启用" : "未启用")
      .accessibilityIdentifier("rss-unread-filter")

      Picker("排序", selection: $presentation.sortOrder) {
        ForEach(RSSArticleSortOrder.allCases) { order in
          Text(order.title).tag(order)
        }
      }
      .pickerStyle(.menu)
      .controlSize(.small)
      .accessibilityIdentifier("rss-sort-picker")

      moreFilterMenu(
        label: advancedFilterCount > 0 ? "筛选 \(advancedFilterCount)" : "筛选",
        systemImage: "line.3.horizontal.decrease.circle",
        includesDate: true,
        availableSources: availableSources,
        availableAuthors: availableAuthors,
        availableTags: availableTags
      )

      clearFiltersButton(showTitle: false)
      Spacer(minLength: 0)
    }
  }

  func moreFilterMenu(
    label: String,
    systemImage: String,
    includesDate: Bool,
    availableSources: [RSSFeed],
    availableAuthors: [String],
    availableTags: [String]
  ) -> some View {
    Menu {
      Section("更多筛选") {
        if includesDate {
          Picker("日期", selection: $presentation.dateRange) {
            ForEach(RSSArticleDateRange.allCases) { range in
              Text(range.title).tag(range)
            }
          }
        }

        if !availableSources.isEmpty, !isSingleFeedScope {
          Picker("来源", selection: $presentation.selectedSourceID) {
            Text("全部来源").tag(UUID?.none)
            ForEach(availableSources) { feed in
              Text(feed.displayTitle).tag(Optional(feed.id))
            }
          }
        }

        if !availableAuthors.isEmpty {
          Picker("作者", selection: $presentation.selectedAuthor) {
            Text("全部作者").tag(String?.none)
            ForEach(availableAuthors, id: \.self) { author in
              Text(author).tag(Optional(author))
            }
          }
        }

        if !availableTags.isEmpty {
          Picker("标签", selection: $presentation.selectedTag) {
            Text("全部标签").tag(String?.none)
            ForEach(availableTags, id: \.self) { tag in
              Text(tag).tag(Optional(tag))
            }
          }
        }
      }

      Divider()
      Toggle("按日期分组", isOn: $presentation.groupsByDate)
    } label: {
      Label(label, systemImage: systemImage)
    }
    .menuStyle(.borderlessButton)
    .controlSize(.small)
    .accessibilityLabel("更多筛选")
    .accessibilityValue(
      advancedFilterCount > 0
        ? "已启用 \(advancedFilterCount) 项来源、作者或标签筛选"
        : "未启用来源、作者或标签筛选"
    )
    .accessibilityIdentifier("rss-more-filters")
  }

  func clearFiltersButton(showTitle: Bool) -> some View {
    Button(
      showTitle ? "清除" : "",
      systemImage: "xmark.circle",
      action: clearFilters
    )
    .buttonStyle(.borderless)
    .controlSize(.small)
    .disabled(!hasActiveFilters)
    .help("清除所有筛选条件")
    .accessibilityLabel("清除筛选")
    .accessibilityIdentifier("rss-clear-filters")
  }

  @ViewBuilder
  func batchSelectionControls(visibleArticles: [RSSArticleHeader]) -> some View {
    HStack(spacing: 8) {
      Text(String(format: String(localized: "已选择 %lld 篇"), selectedBatchArticleIDs.count))
        .font(.callout.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityLabel("已选择 \(selectedBatchArticleIDs.count) 篇文章")

      Button("全选当前显示文章", systemImage: "checklist.checked") {
        selectedBatchArticleIDs.formUnion(visibleArticles.map(\.id))
      }
      .buttonStyle(.borderless)
      .disabled(visibleArticles.isEmpty)

      Button("清除选择", systemImage: "xmark.circle") {
        selectedBatchArticleIDs.removeAll()
      }
      .buttonStyle(.borderless)
      .disabled(selectedBatchArticleIDs.isEmpty)

      Button("保存所选文章", systemImage: "tray.and.arrow.down") {
        onBatchSaveToKnowledge(Array(selectedBatchArticleIDs))
      }
      .workbenchProminentActionStyle()
      .disabled(selectedBatchArticleIDs.isEmpty || workflowIsBusy)
      .accessibilityLabel("将已选择的 \(selectedBatchArticleIDs.count) 篇文章保存到资料库")

      Button("退出批量选择（Esc）", systemImage: "escape") {
        endBatchSelection()
      }
      .buttonStyle(.borderless)
    }
    .controlSize(.small)
    .padding(.top, 2)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("RSS 文章批量操作")
  }

  func toggleBatchSelection(_ articleID: String) {
    if selectedBatchArticleIDs.contains(articleID) {
      selectedBatchArticleIDs.remove(articleID)
    } else {
      selectedBatchArticleIDs.insert(articleID)
    }
  }

  func endBatchSelection() {
    isBatchSelectionMode = false
    selectedBatchArticleIDs.removeAll()
  }

}
