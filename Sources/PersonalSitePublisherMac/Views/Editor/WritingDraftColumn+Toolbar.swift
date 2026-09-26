import PublishingWorkbenchCore
import SwiftUI

extension WritingDraftColumn {
  var writingHeader: some View {
    WorkspaceContextListHeader(title: "文章") {
      HStack(spacing: 6) {
        Text(String(localized: "\(filteredDraftCount) / \(visibleDraftCount) 篇"))
          .lineLimit(1)
          .fixedSize()

        if let delta = draftCountDelta {
          Text(delta > 0 ? "+\(delta)" : "\(delta)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(delta > 0 ? WorkbenchTheme.success : WorkbenchTheme.risk)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
              (delta > 0 ? WorkbenchTheme.success : WorkbenchTheme.risk)
                .opacity(WorkbenchOpacity.accentBackground),
              in: Capsule()
            )
            .fixedSize()
        }
      }
    } actions: {
      if isDraftListLoading && visibleDraftSnapshot.isEmpty {
        ProgressView()
          .controlSize(.small)
          .help(String(localized: "加载草稿中…"))
      }

      if store.canUndoLatestDraftOwnershipTransfer {
        Button {
          _ = store.undoLatestDraftOwnershipTransfer()
        } label: {
          WorkspaceSidebarHeaderIcon("arrow.uturn.backward")
        }
        .buttonStyle(.plain)
        .help(String(localized: "撤销上次归属变更"))
        .accessibilityLabel("撤销上次归属变更")
      }

      Button {
        store.flushDraftBodyEditorBuffers()
        openDataManagement(.drafts)
      } label: {
        // Icon-only like the neighbouring header actions so the article count
        // keeps its space when the sidebar narrows beside the Inspector.
        WorkspaceSidebarHeaderIcon("archivebox")
      }
      .buttonStyle(.plain)
      .help(String(localized: "集中管理版本、回收站、备份和迁移"))
      .accessibilityLabel("打开数据管理")

      Menu {
        Button {
          isAIBatchMaintenancePresented = true
        } label: {
          Label("AI 批量维护", systemImage: "sparkles.rectangle.stack")
        }
        Divider()
        Button {
          store.createDraft()
        } label: {
          Label("新建站点文章", systemImage: "doc.badge.plus")
        }

        Button {
          store.createGeneralDraft()
        } label: {
          Label("新建通用草稿", systemImage: "square.and.pencil")
        }

        Divider()

        Button {
          isTemplatePickerPresented = true
        } label: {
          Label("从模板新建…", systemImage: "doc.text.image")
        }
      } label: {
        Label("新建", systemImage: "plus")
          .labelStyle(.titleAndIcon)
          .font(.workbenchButtonLabel.weight(.bold))
          .foregroundStyle(WorkbenchTheme.primaryActionForeground)
          .padding(.horizontal, 10)
          .frame(height: 28)
          .background(
            WorkbenchTheme.primaryActionFill,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
          )
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .controlSize(.regular)
      .fixedSize()
      .help("新建文章或通用草稿")
      .accessibilityLabel("新建文章或通用草稿")
      .accessibilityIdentifier("writing-create-menu")
    }
  }

  var draftListToolbar: some View {
    VStack(spacing: 8) {
      if selectedDraftIDs.count > 1 {
        bulkSelectionBar
      }

      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .font(.footnote)

        // Short prompt so it never clips in a 240 pt sidebar; the accessibility
        // label keeps the full description of the searched fields.
        TextField(
          "搜索文章",
          text: Binding(get: { searchText }, set: { searchText = $0 })
        )
          .textFieldStyle(.plain)
          .focused($isSearchFieldFocused)
          .accessibilityLabel("搜索标题、摘要、标签或路径")
          .accessibilityValue(searchText.nilIfEmpty ?? String(localized: "未输入"))
          .accessibilityIdentifier("writing-draft-search")

        if !searchText.isEmpty {
          Button {
            searchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help(String(localized: "清除搜索"))
          .accessibilityLabel("清除草稿搜索")
        }

        // Full-text search is a scope of the same search, so it lives inside
        // the field instead of occupying its own sidebar row.
        Button {
          sceneCommandRouter.draftFullTextSearchAction?.open(
            DraftFullTextSearchRequest(
              query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
              scope: store.draftListContentScope == .general ? .generalDrafts : .currentSite
            )
          )
        } label: {
          Image(systemName: "doc.text.magnifyingglass")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("搜索正文…")
        .accessibilityLabel("打开跨文章全文搜索")
        .accessibilityIdentifier("writing-draft-full-text-search")
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        WorkbenchBackgroundStyle.control,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))

      if filter != .all || !searchText.isEmpty {
        HStack(spacing: 6) {
          Image(systemName: "line.3.horizontal.decrease.circle.fill")
            .font(.caption)
            .foregroundStyle(Color.accentColor)
          Text(
            filter != .all
              ? String(format: String(localized: "已筛选：%@"), filter.localizedDisplayName)
              : String(format: String(localized: "搜索：“%@”"), searchText)
          )
          .font(.workbenchMetadata)
          .foregroundStyle(.secondary)
          .lineLimit(1)

          Spacer(minLength: 0)

          Button {
            filter = .all
            searchText = ""
          } label: {
            HStack(spacing: 2) {
              Text(String(localized: "清除筛选"))
              Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
            }
            .font(.workbenchMetadata)
            .foregroundStyle(Color.accentColor)
          }
          .buttonStyle(.plain)
          .help(String(localized: "重置所有筛选与搜索条件"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
          Color.accentColor.opacity(0.08),
          in: RoundedRectangle(cornerRadius: 6)
        )
      }

      // A 240pt sidebar beside the Inspector cannot hold the filter, scope
      // picker and list menus on one line; stack the scope picker instead of
      // letting the row overflow and shift the whole column.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 6) {
          draftListFilterControls
          contentScopePicker
          Spacer(minLength: 0)
          draftListArrangementMenus
        }

        VStack(alignment: .leading, spacing: 6) {
          contentScopePicker
          HStack(spacing: 6) {
            draftListFilterControls
            Spacer(minLength: 0)
            draftListArrangementMenus
          }
        }
      }
    }
  }

  @ViewBuilder
  private var draftListFilterControls: some View {
    if isCompact {
      // Filtering is folded into the display-options menu.
      EmptyView()
    } else {
      ForEach(DraftListFilter.primaryFilters) { candidate in
        Button(candidate.localizedDisplayName) {
          filter = candidate
        }
        .buttonStyle(.bordered)
        .tint(filter == candidate ? .accentColor : .secondary)
        .controlSize(.small)
        .accessibilityAddTraits(filter == candidate ? .isSelected : [])
      }

      Menu {
        ForEach(DraftListFilter.overflowFilters) { candidate in
          filterButton(candidate)
        }
      } label: {
        Label(overflowFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
      }
      .menuIndicator(.hidden)
      .controlSize(.small)
      .accessibilityLabel("更多草稿筛选")
      .accessibilityValue(filter.localizedDisplayName)
    }
  }

  /// One menu for filter (in compact layouts), grouping and sorting keeps the
  /// scope picker and all list options on a single sidebar row.
  @ViewBuilder
  private var draftListArrangementMenus: some View {
    Menu {
      if isCompact {
        Section(String(localized: "筛选")) {
          ForEach(DraftListFilter.allCases) { candidate in
            filterButton(candidate)
          }
        }
      }
      Section(String(localized: "排序")) {
        ForEach(WritingDraftSortOrder.allCases) { option in
          Button {
            sortOrderRawValue = option.rawValue
          } label: {
            if sortOrder == option {
              Label(option.localizedDisplayName, systemImage: "checkmark")
            } else {
              Text(option.localizedDisplayName)
            }
          }
        }
      }
      Section(String(localized: "文章分组方式")) {
        ForEach(WritingDraftListDisplayMode.allCases) { option in
          Button {
            displayModeRawValue = option.rawValue
          } label: {
            if displayMode == option {
              Label(writingDraftDisplayModeName(option), systemImage: "checkmark")
            } else {
              Text(writingDraftDisplayModeName(option))
            }
          }
        }
        if store.draftListContentScope == .general {
          Divider()
          Button {
            beginCreatingGeneralFolder(for: Array(selectedDraftIDs))
          } label: {
            Label("新建文件夹并移入所选草稿…", systemImage: "folder.badge.plus")
          }
          .disabled(selectedDraftIDs.isEmpty)
        }
      }
    } label: {
      Image(
        systemName: isCompact && filter != .all
          ? "line.3.horizontal.decrease.circle.fill"
          : "line.3.horizontal.decrease.circle"
      )
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(
      String(
        localized:
          "显示选项：\(filter.localizedDisplayName) · \(sortOrder.localizedDisplayName) · \(writingDraftDisplayModeName(effectiveDisplayMode))"
      )
    )
    .accessibilityLabel(String(localized: "文章显示选项"))
    .accessibilityValue(
      "\(filter.localizedDisplayName)，\(sortOrder.localizedDisplayName)，\(writingDraftDisplayModeName(effectiveDisplayMode))"
    )
    .accessibilityIdentifier("writing-draft-display-mode")
  }

  private var contentScopePicker: some View {
    Picker("内容范围", selection: contentScopeSelection) {
      Text("当前站点").tag(DraftListContentScope.currentSite)
      Text(String(localized: "通用草稿", comment: "草稿范围：通用草稿")).tag(DraftListContentScope.general)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .controlSize(.regular)
    .font(.workbenchButtonLabel)
    .frame(minWidth: 150, idealWidth: 150, maxWidth: 200)
    .accessibilityLabel("内容范围")
  }

  private var overflowFilterLabel: String {
    DraftListFilter.primaryFilters.contains(filter)
      ? String(localized: "更多")
      : filter.localizedDisplayName
  }

  private func writingDraftDisplayModeName(_ mode: WritingDraftListDisplayMode) -> String {
    switch mode {
    case .flat:
      return String(localized: "列表")
    case .folders:
      return String(localized: "文件夹")
    }
  }

  @ViewBuilder
  private func filterButton(_ candidate: DraftListFilter) -> some View {
    Button {
      filter = candidate
    } label: {
      if filter == candidate {
        Label(candidate.localizedDisplayName, systemImage: "checkmark")
      } else {
        Text(candidate.localizedDisplayName)
      }
    }
    .accessibilityAddTraits(filter == candidate ? .isSelected : [])
  }
}
