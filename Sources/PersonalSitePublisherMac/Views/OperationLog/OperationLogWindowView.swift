import SwiftUI

struct OperationLogWindowView: View {
  let allEntries: [OperationLogPresentation.Entry]
  let siteProfiles: [OperationLogPresentation.SiteProfileOption]
  let isQuickHideActive: Bool
  let retentionPolicy: OperationLogPresentation.RetentionPolicy
  let statusMessage: String?
  let openSyncWorkspace: () -> Void
  let setRetentionPolicy: (OperationLogPresentation.RetentionPolicy) -> Void
  let clearOperationLog: () -> Void
  let dismissStatusMessage: () -> Void
  @State private var selectionID: String?
  @State private var filters = OperationLogPresentation.Filters()
  @State private var exportDocument = OperationLogExportDocument(entries: [])
  @State private var isExportPresented = false
  @State private var isPreparingExport = false
  @State private var isClearConfirmationPresented = false
  @State private var exportErrorMessage: String?

  var body: some View {
    Group {
      if isQuickHideActive {
        quickHideContent
      } else {
        operationLogContent
      }
    }
    .frame(minWidth: 760, minHeight: 520)
    .accessibilityIdentifier("operation-log-window")
  }

  private var operationLogContent: some View {
    let filtered = OperationLogPresentation.filteredSections(
      allEntries,
      filters: filters
    )
    let filteredEntries = filtered.entries

    return NavigationSplitView {
      operationList(entries: filteredEntries, sections: filtered.sections)
    } detail: {
      operationDetail(entries: filteredEntries)
    }
    .searchable(
      text: $filters.searchText,
      placement: .sidebar,
      prompt: String(localized: "搜索活动记录")
    )
    .toolbar { filterToolbar }
    .fileExporter(
      isPresented: $isExportPresented,
      document: exportDocument,
      contentType: .json,
      defaultFilename: exportFilename
    ) { result in
      if case .failure = result {
        exportErrorMessage = String(localized: "导出活动记录失败。")
      }
    }
    .confirmationDialog(
      "清空活动记录？",
      isPresented: $isClearConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("清空活动记录", role: .destructive) {
        clearOperationLog()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("活动窗口会清空，但发布台账、维护记录等业务事实不会删除。")
    }
    .alert("活动记录状态", isPresented: statusAlertPresented) {
      Button("好") {
        if statusMessage != nil {
          dismissStatusMessage()
        }
        exportErrorMessage = nil
      }
    } message: {
      Text(displayedStatusMessage ?? "")
    }
    .onAppear { reconcileSelection(in: filteredEntries) }
    .onChange(of: filteredEntries.map(\.id)) { _, _ in
      reconcileSelection(in: filteredEntries)
    }
  }

  private var quickHideContent: some View {
    ContentUnavailableView {
      Label("活动记录已隐藏", systemImage: "eye.slash")
    } description: {
      Text("快速隐藏已启用。请返回主工作台恢复显示后，再查看活动记录。")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("operation-log-quick-hide")
  }

  private func operationList(
    entries: [OperationLogPresentation.Entry],
    sections: [OperationLogPresentation.DaySection]
  ) -> some View {
    Group {
      if entries.isEmpty {
        ContentUnavailableView {
          Label("没有匹配的活动记录", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
          Text("尝试调整搜索词或筛选条件。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(selection: $selectionID) {
          ForEach(sections) { section in
            Section(section.day.formatted(.dateTime.year().month().day())) {
              ForEach(section.entries) { entry in
                OperationLogRow(entry: entry)
                  .tag(entry.id)
              }
            }
          }
        }
        .listStyle(.sidebar)
      }
    }
    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
  }

  @ViewBuilder
  private func operationDetail(entries: [OperationLogPresentation.Entry]) -> some View {
    if let selected = entries.first(where: { $0.id == selectionID }) {
      OperationLogDetailView(entry: selected, openSyncWorkspace: openSyncWorkspace)
    } else {
      ContentUnavailableView {
        Label("未选择活动记录", systemImage: "list.bullet.rectangle")
      } description: {
        Text("从左侧选择一条记录以查看安全摘要。")
      }
    }
  }

  @ToolbarContentBuilder
  private var filterToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .automatic) {
      Menu {
        Picker("类别", selection: $filters.category) {
          Text("全部类别").tag(OperationLogPresentation.Category?.none)
          Divider()
          ForEach(OperationLogPresentation.Category.allCases, id: \.self) { category in
            Text(category.title).tag(Optional(category))
          }
        }

        Picker("结果", selection: $filters.outcome) {
          Text("全部结果").tag(OperationLogPresentation.Outcome?.none)
          Divider()
          ForEach(OperationLogPresentation.Outcome.allCases, id: \.self) { outcome in
            Text(outcome.title).tag(Optional(outcome))
          }
        }

        Picker("站点", selection: $filters.profileID) {
          Text("全部站点").tag(UUID?.none)
          Divider()
          ForEach(siteProfiles) { profile in
            Text(profile.name).tag(Optional(profile.id))
          }
        }

        Picker("时间范围", selection: $filters.timeRange) {
          ForEach(OperationLogPresentation.TimeRange.allCases, id: \.self) { range in
            Text(range.title).tag(range)
          }
        }
      } label: {
        Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
      }
      .accessibilityIdentifier("operation-log-filter-menu")

      Menu {
        Picker("保留期限", selection: retentionPolicyBinding) {
          ForEach(OperationLogPresentation.RetentionPolicy.allCases) { policy in
            Text(policy.title).tag(policy)
          }
        }

        Divider()

        Button {
          prepareExport()
        } label: {
          if isPreparingExport {
            Label("正在准备导出…", systemImage: "hourglass")
          } else {
            Label("导出活动记录…", systemImage: "square.and.arrow.up")
          }
        }
        .disabled(isPreparingExport)
        .accessibilityIdentifier("operation-log-export")

        Divider()

        Button(role: .destructive) {
          if OperationLogPresentation.canPresentClearConfirmation(
            isQuickHideActive: isQuickHideActive,
            visibleEntries: allEntries
          ) {
            isClearConfirmationPresented = true
          }
        } label: {
          Label("清空活动记录…", systemImage: "trash")
        }
        .disabled(
          !OperationLogPresentation.canPresentClearConfirmation(
            isQuickHideActive: isQuickHideActive,
            visibleEntries: allEntries
          )
        )
        .accessibilityIdentifier("operation-log-clear")
      } label: {
        Label("管理", systemImage: "ellipsis.circle")
      }
      .accessibilityIdentifier("operation-log-management-menu")
    }
  }

  private var retentionPolicyBinding: Binding<OperationLogPresentation.RetentionPolicy> {
    Binding(
      get: { retentionPolicy },
      set: { policy in
        setRetentionPolicy(policy)
      }
    )
  }

  private func prepareExport() {
    let entries = allEntries
    let activeFilters = filters
    isPreparingExport = true
    Task {
      let data = await Task.detached(priority: .utility) {
        OperationLogExportDocument.exportData(
          for: OperationLogPresentation.filtered(entries, filters: activeFilters)
        )
      }.value
      exportDocument = OperationLogExportDocument(data: data)
      isPreparingExport = false
      isExportPresented = true
    }
  }

  private var displayedStatusMessage: String? {
    statusMessage ?? exportErrorMessage
  }

  private var statusAlertPresented: Binding<Bool> {
    Binding(
      get: { displayedStatusMessage != nil },
      set: { isPresented in
        guard !isPresented else { return }
        if statusMessage != nil {
          dismissStatusMessage()
        }
        exportErrorMessage = nil
      }
    )
  }

  private var exportFilename: String {
    let date = Date().formatted(.dateTime.year().month().day())
    return "RepoPress-activity-\(date)"
  }

  private func reconcileSelection(in entries: [OperationLogPresentation.Entry]) {
    selectionID = OperationLogPresentation.reconciledSelection(selectionID, in: entries)
  }

}
