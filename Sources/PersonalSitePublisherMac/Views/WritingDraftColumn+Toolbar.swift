import PublishingWorkbenchCore
import SwiftUI

extension WritingDraftColumn {
  var writingHeader: some View {
    WorkspaceContextListHeader(title: "文章") {
      HStack(spacing: 6) {
        Text(String(localized: "\(filteredDraftCount) / \(visibleDraftCount) 篇"))

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
            .scaleEffect(isDraftCountPunching ? 1.06 : 1)
            .animation(WorkbenchMotion.emphasisSpring, value: isDraftCountPunching)
            .transition(.scale.combined(with: .opacity))
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
        Label("数据管理", systemImage: "externaldrive")
      }
      .buttonStyle(.bordered)
      .controlSize(.regular)
      .fixedSize()
      .help(String(localized: "集中管理版本、回收站、备份和迁移"))
      .accessibilityLabel("打开数据管理")

      Menu {
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
      } label: {
        Color.clear
          .frame(width: 66, height: 28)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .frame(width: 66, height: 28)
      .background(
        WorkbenchTheme.primaryActionFill,
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .overlay {
        Label("新建", systemImage: "plus")
          .labelStyle(.titleAndIcon)
          .font(.workbenchButtonLabel.weight(.bold))
          .foregroundStyle(WorkbenchTheme.primaryActionForeground)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
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

        TextField("搜索草稿", text: $searchText)
          .textFieldStyle(.plain)
          .focused($isSearchFieldFocused)
          .accessibilityLabel("搜索草稿")
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
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        WorkbenchBackgroundStyle.control,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))

      HStack(spacing: 6) {
        if isCompact {
          draftFilterMenu
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

        contentScopePicker

        Spacer(minLength: 0)

        Menu {
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
        } label: {
          Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(String(localized: "排序：\(sortOrder.localizedDisplayName)"))
        .accessibilityLabel("文章排序")
        .accessibilityValue(sortOrder.localizedDisplayName)
      }
    }
  }

  private var contentScopePicker: some View {
    Picker("内容范围", selection: contentScopeSelection) {
      Text("当前站点").tag(DraftListContentScope.currentSite)
      Text("draft.scope.general").tag(DraftListContentScope.general)
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .controlSize(.regular)
    .font(.workbenchButtonLabel)
    .frame(minWidth: 150, idealWidth: 180, maxWidth: 200)
    .accessibilityLabel("内容范围")
  }

  private var overflowFilterLabel: String {
    DraftListFilter.primaryFilters.contains(filter)
      ? String(localized: "更多")
      : filter.localizedDisplayName
  }

  private var draftFilterMenu: some View {
    Menu {
      ForEach(DraftListFilter.allCases) { candidate in
        filterButton(candidate)
      }
    } label: {
      Label(filter.localizedDisplayName, systemImage: "line.3.horizontal.decrease.circle")
        .lineLimit(1)
    }
    .menuIndicator(.hidden)
    .controlSize(.small)
    .accessibilityLabel("草稿筛选")
    .accessibilityValue(filter.localizedDisplayName)
    .help(String(localized: "筛选草稿"))
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
