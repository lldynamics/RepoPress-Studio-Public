import PublishingWorkbenchCore
import SwiftUI

extension WritingDraftColumn {
  var writingHeader: some View {
    WorkspaceContextListHeader(title: "文章") {
      HStack(spacing: 6) {
        // Only show "shown / total" when a filter or search hides some articles.
        Text(
          filteredDraftCount == visibleDraftCount
            ? String(localized: "\(visibleDraftCount) 篇")
            : String(localized: "\(filteredDraftCount) / \(visibleDraftCount) 篇")
        )
        .lineLimit(1)
        .fixedSize()

        if let delta = draftCountDelta {
          Text(delta > 0 ? "+\(delta)" : "\(delta)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(delta > 0 ? WorkbenchTheme.success : WorkbenchTheme.risk)
            .padding(.horizontal, WorkbenchSpacing.icon)
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

      // Creation is a compact icon so the only filled primary action on screen
      // stays "准备发布"; ⌘N creates an article from anywhere.
      Button {
        store.createDraft()
      } label: {
        WorkspaceSidebarHeaderIcon("square.and.pencil")
      }
      .buttonStyle(.plain)
      .help(String(localized: "新建站点文章（⌘N）"))
      .accessibilityLabel("新建站点文章")
      .accessibilityIdentifier("writing-create-article")

      Menu {
        Button {
          store.createGeneralDraft()
        } label: {
          Label("新建通用草稿", systemImage: "square.and.pencil")
        }

        Button {
          isTemplatePickerPresented = true
        } label: {
          Label("从模板新建…", systemImage: "doc.text.image")
        }

        Divider()

        Button {
          store.flushDraftBodyEditorBuffers()
          openDataManagement(.drafts)
        } label: {
          Label("版本、回收站与备份…", systemImage: "archivebox")
        }
        .accessibilityIdentifier("writing-open-data-management")
      } label: {
        WorkspaceSidebarHeaderIcon("ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("其他新建选项、版本、回收站与备份")
      .accessibilityLabel("其他新建选项与数据管理")
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
        .help("在命令面板中搜索文章正文")
        .accessibilityLabel("在命令面板中搜索文章正文")
        .accessibilityIdentifier("writing-draft-full-text-search")
      }
      .padding(.horizontal, WorkbenchSpacing.control)
      .padding(.vertical, WorkbenchSpacing.icon)
      .background(
        WorkbenchBackgroundStyle.control,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))

      if filter != .all || !searchText.isEmpty {
        HStack(spacing: 6) {
          Image(systemName: "line.3.horizontal.decrease.circle.fill")
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.info)
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
                .font(.system(size: WorkbenchIconSize.indicator, weight: .bold))
            }
            .font(.workbenchMetadata)
            .foregroundStyle(WorkbenchTheme.info)
          }
          .buttonStyle(.plain)
          .help(String(localized: "重置所有筛选与搜索条件"))
        }
        .padding(.horizontal, WorkbenchSpacing.control)
        .padding(.vertical, WorkbenchSpacing.tight)
        .background(
          WorkbenchTheme.info.opacity(0.08),
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        )
      }

      HStack(spacing: WorkbenchSpacing.tight) {
        contentScopePicker
        Spacer(minLength: 0)
        draftListArrangementMenus
      }

      ViewThatFits(in: .horizontal) {
        HStack(spacing: WorkbenchSpacing.control) {
          draftListFilterMenu.fixedSize()
          Spacer(minLength: 0)
          draftListSortMenu.fixedSize()
        }
        VStack(alignment: .leading, spacing: WorkbenchSpacing.tight) {
          draftListFilterMenu
          draftListSortMenu
        }
      }
    }
  }

  private var draftListFilterMenu: some View {
    Menu {
      ForEach(DraftListFilter.primaryFilters) { candidate in
        filterButton(candidate)
      }
      Divider()
      ForEach(DraftListFilter.overflowFilters) { candidate in
        filterButton(candidate)
      }
    } label: {
      Label(filter.localizedDisplayName, systemImage: "line.3.horizontal.decrease")
        .font(.workbenchSupporting)
        .lineLimit(1)
    }
    .menuStyle(.borderlessButton)
    .help(filter.localizedDisplayName)
    .accessibilityLabel("筛选")
    .accessibilityValue(filter.localizedDisplayName)
    .accessibilityIdentifier("writing-draft-filter")
  }

  private var draftListSortMenu: some View {
    Menu {
      Picker("排序", selection: $sortOrderRawValue) {
        ForEach(WritingDraftSortOrder.allCases) { option in
          Text(option.localizedDisplayName).tag(option.rawValue)
        }
      }
    } label: {
      Label(sortOrder.localizedDisplayName, systemImage: "arrow.up.arrow.down")
        .font(.workbenchSupporting)
        .lineLimit(1)
    }
    .menuStyle(.borderlessButton)
    .help(sortOrder.localizedDisplayName)
    .accessibilityLabel("排序")
    .accessibilityValue(sortOrder.localizedDisplayName)
    .accessibilityIdentifier("writing-draft-sort")
  }

  private var draftListArrangementMenus: some View {
    Menu {
      Picker("文章分组方式", selection: $displayModeRawValue) {
        ForEach(WritingDraftListDisplayMode.allCases) { option in
          Text(writingDraftDisplayModeName(option)).tag(option.rawValue)
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
    } label: {
      Image(systemName: effectiveDisplayMode == .folders ? "folder" : "list.bullet")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help(writingDraftDisplayModeName(effectiveDisplayMode))
    .accessibilityLabel(String(localized: "文章显示选项"))
    .accessibilityValue(writingDraftDisplayModeName(effectiveDisplayMode))
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
