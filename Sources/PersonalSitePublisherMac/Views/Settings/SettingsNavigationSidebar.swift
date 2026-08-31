import SwiftUI

struct SettingsNavigationList: View {
  let searchText: String
  let searchItems: [SettingsSearchItem]
  @Binding var selection: SettingsRoute
  let tabsNeedingAttention: Set<SettingsTab>
  let rowVerticalPadding: CGFloat
  let subsectionVerticalPadding: CGFloat
  let selectSearchItem: (SettingsSearchItem) -> Void

  var body: some View {
    List(selection: $selection) {
      if isSearching {
        searchResults
      } else {
        pageSection("当前站点", tabs: SettingsTab.siteSettings)
        pageSection("应用", tabs: SettingsTab.applicationSettings)
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .scrollIndicators(.hidden)
    .accessibilityIdentifier("settings-sidebar")
  }

  private var isSearching: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  @ViewBuilder
  private var searchResults: some View {
    if searchItems.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        Text("未找到匹配的设置项")
          .font(.callout.weight(.medium))
          .foregroundStyle(.secondary)
        Text("可尝试搜索“Token”、“主题”、“Ollama”或“路径”")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, WorkbenchSpacing.control)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("settings-search-empty")
    } else {
      Section {
        ForEach(searchItems) { item in
          Button {
            selectSearchItem(item)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Label(item.sectionTitle, systemImage: item.systemImage)
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.primary)
                .lineLimit(1)

              Text("\(item.tab.title) · \(item.detail)")
                .font(.workbenchMetadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
          .accessibilityElement(children: .combine)
          .accessibilityLabel("\(item.sectionTitle)，属于 \(item.tab.title)")
          .accessibilityIdentifier("settings-search-result-\(item.id)")
        }
      } header: {
        sidebarSectionHeader("搜索结果")
      }
      .accessibilityIdentifier("settings-search-results")
    }
  }

  @ViewBuilder
  private func pageSection(
    _ title: LocalizedStringKey,
    tabs: [SettingsTab]
  ) -> some View {
    Section {
      ForEach(tabs) { tab in
        pageRow(tab)

        if selection.tab == tab {
          let subsections = SettingsSubsection.sections(for: tab)
          if subsections.count > 1 {
            ForEach(subsections) { subsection in
              subsectionRow(subsection)
            }
          }
        }
      }
    } header: {
      sidebarSectionHeader(title)
    }
  }

  private func pageRow(_ tab: SettingsTab) -> some View {
    let needsAttention = tabsNeedingAttention.contains(tab)
    return HStack(spacing: WorkbenchSpacing.control) {
      Image(systemName: tab.systemImage)
        .foregroundStyle(selection.tab == tab ? Color.accentColor : Color.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)

      Text(tab.title)
        .lineLimit(1)

      Spacer(minLength: 2)

      if needsAttention {
        Text(SettingsSidebarPresentation.attentionBadgeTitle)
          .font(.workbenchMetadata.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.warning)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(
            WorkbenchTheme.warning.opacity(WorkbenchOpacity.noticeBackground),
            in: Capsule()
          )
          .fixedSize()
          .accessibilityHidden(true)
      }
    }
    .padding(.vertical, rowVerticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .tag(SettingsRoute.tab(tab))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(tab.title)
    .accessibilityValue(
      needsAttention ? SettingsSidebarPresentation.attentionAccessibilityValue : ""
    )
    .accessibilityIdentifier("settings-tab-\(tab.id)")
  }

  private func subsectionRow(_ subsection: SettingsSubsection) -> some View {
    HStack(spacing: WorkbenchSpacing.control) {
      Image(systemName: subsection.systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 16)
        .accessibilityHidden(true)

      Text(subsection.title)
        .font(.callout)
        .lineLimit(1)
    }
    .padding(.leading, WorkbenchSpacing.spacious)
    .padding(.vertical, subsectionVerticalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .tag(SettingsRoute.subsection(subsection))
    .accessibilityLabel("\(subsection.title)，\(subsection.subtitle)")
    .accessibilityIdentifier("settings-subsection-\(subsection.id)")
  }

  private func sidebarSectionHeader(_ title: LocalizedStringKey) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .textCase(nil)
  }
}

struct SettingsDetailHeader: View {
  let tab: SettingsTab
  let subsection: SettingsSubsection
  let minimumHeight: CGFloat

  var body: some View {
    HStack(alignment: .top, spacing: WorkbenchSpacing.section) {
      VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
        HStack(spacing: WorkbenchSpacing.card) {
          Text(tab.title)
            .font(.title2.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("settings-detail-title")

          scopeBadge
        }

        Label(subsection.title, systemImage: subsection.systemImage)
          .font(.headline)

        Text(subsection.subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: WorkbenchSpacing.content)
    }
    .padding(.horizontal, WorkbenchSpacing.spacious)
    .padding(.vertical, WorkbenchSpacing.content)
    .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var scopeBadge: some View {
    Label(
      tab.isSiteScoped ? "当前站点" : "全局共享",
      systemImage: tab.isSiteScoped ? "globe.asia.australia" : "globe"
    )
    .font(.caption.weight(.medium))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(Color.primary.opacity(0.06), in: Capsule())
    .accessibilityLabel(
      tab.isSiteScoped ? "当前站点，切换站点后可分别配置" : "全局共享，适用于所有站点"
    )
  }
}
