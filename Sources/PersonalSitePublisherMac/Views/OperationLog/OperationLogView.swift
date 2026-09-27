import SwiftUI

struct OperationLogView: View {
  let allEntries: [OperationLogPresentation.Entry]
  let siteProfiles: [OperationLogPresentation.SiteProfileOption]
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
    operationLogContent
      .frame(minWidth: 760, minHeight: 440)
      .accessibilityIdentifier("workspace-task-center-activity")
  }

  private var operationLogContent: some View {
    let filtered = OperationLogPresentation.filteredSections(
      allEntries,
      filters: filters
    )
    let filteredEntries = filtered.entries

    return VStack(spacing: 0) {
      activityToolbar
      Divider()
      HSplitView {
        operationList(entries: filteredEntries, sections: filtered.sections)
          .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
        operationDetail(entries: filteredEntries)
          .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
      }
    }
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
      Text("活动记录会清空，但发布记录、维护记录等业务事实不会删除。")
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

  private var activityToolbar: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField("搜索活动记录", text: $filters.searchText)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("搜索活动记录")
        .accessibilityIdentifier("operation-log-search")
      filterToolbar
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
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

  private var filterToolbar: some View {
    HStack(spacing: 8) {
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
            visibleEntries: allEntries
          ) {
            isClearConfirmationPresented = true
          }
        } label: {
          Label("清空活动记录…", systemImage: "trash")
        }
        .disabled(
          !OperationLogPresentation.canPresentClearConfirmation(
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
