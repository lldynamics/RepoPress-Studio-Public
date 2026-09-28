import AppKit
import PublishingDomainContracts
import QuickLook
import SwiftUI

struct RepositoryImageBrowserView: View {
  @ObservedObject var session: RepositoryImageBrowserSession
  let isWorking: Bool
  let onRefresh: () -> Void
  let onProcess: (ImageWorkbenchBatchAction) -> Void
  let onOpenRepositorySettings: () -> Void
  @FocusState private var galleryFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header.padding(20)
      if session.isLoading && session.inventory == nil {
        ProgressView("正在读取仓库图片…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error = session.errorMessage, session.inventory == nil {
        EmptyStateView(
          title: "暂时无法读取仓库图片", message: LocalizedStringKey(error),
          systemImage: "folder.badge.questionmark", density: .compactPane,
          actionTitle: "打开仓库与发布", action: onOpenRepositorySettings
        )
      } else if session.visibleAssets.isEmpty {
        emptyState
      } else {
        images
      }
      Divider()
      statusBar
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("仓库图片")
    .accessibilityIdentifier("repository-image-browser")
    .task(id: projectionInput) { await session.rebuildProjection() }
    .quickLookPreview($session.previewURL)
  }

  private var projectionInput: String {
    [
      session.inventory?.revisionID.uuidString ?? "", String(describing: session.scope),
      session.query, session.filter.rawValue, session.sortOrder.rawValue,
      String(session.includesSubfolders),
    ].joined(separator: "\u{0}")
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      breadcrumb
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 16) {
          introduction
          Spacer(minLength: 4)
          searchField.frame(minWidth: 160, maxWidth: 360)
          refreshButton
          displayPicker
        }
        VStack(alignment: .leading, spacing: 8) {
          introduction
          HStack {
            searchField
            refreshButton
            displayPicker
          }
        }
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          scopeToggle
          Spacer(minLength: 2)
          filters
          processMenu
        }
        VStack(alignment: .leading, spacing: 8) {
          scopeToggle
          HStack {
            filters
            Spacer(minLength: 2)
            processMenu
          }
        }
      }
      if let error = session.errorMessage, session.inventory != nil {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.workbenchSupporting).foregroundStyle(WorkbenchTheme.warning)
      }
      if session.inventory?.wasTruncated == true {
        Label("图片或目录过多，当前显示部分扫描结果。", systemImage: "exclamationmark.triangle")
          .font(.workbenchSupporting).foregroundStyle(WorkbenchTheme.warning)
      }
    }
  }

  private var introduction: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(session.title).font(.workbenchPageTitle).lineLimit(1)
      Text("\(session.visibleAssets.count) 张图片")
        .font(.workbenchSupporting).foregroundStyle(.secondary)
    }
  }

  private var breadcrumb: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 5) {
        Button("全部图片") { session.scope = .all }
          .buttonStyle(.borderless)
        if case .folder(let path) = session.scope {
          let components = path.split(separator: "/").map(String.init)
          ForEach(Array(components.enumerated()), id: \.offset) { index, component in
            Image(systemName: "chevron.right").accessibilityHidden(true)
            Button(component) {
              session.scope = .folder(components.prefix(index + 1).joined(separator: "/"))
            }
            .buttonStyle(.borderless)
            .disabled(
              components.prefix(index + 1).joined(separator: "/").count
                < (session.inventory?.assetRootPath.count ?? 0))
          }
        }
      }
      .font(.workbenchSupporting).foregroundStyle(.secondary)
    }
    .accessibilityLabel("图片目录路径")
  }

  private var searchField: some View {
    TextField("搜索文件名或仓库路径", text: $session.query)
      .textFieldStyle(.roundedBorder)
      .accessibilityLabel("搜索当前图片范围")
      .accessibilityIdentifier("repository-image-search")
  }

  private var refreshButton: some View {
    Button(action: onRefresh) { Label("重新扫描", systemImage: "arrow.clockwise") }
      .labelStyle(.iconOnly).disabled(session.isLoading)
      .help("重新扫描图片和目录")
      .accessibilityIdentifier("image-workbench-refresh")
  }

  private var displayPicker: some View {
    Picker("图片显示方式", selection: $session.displayMode) {
      Image(systemName: "square.grid.2x2").tag(RepositoryImageDisplayMode.grid)
      Image(systemName: "list.bullet").tag(RepositoryImageDisplayMode.list)
    }
    .pickerStyle(.segmented).labelsHidden().frame(width: 72)
    .accessibilityLabel("图片显示方式")
    .accessibilityIdentifier("repository-image-display-mode")
  }

  private var scopeToggle: some View {
    Toggle("包含子文件夹", isOn: $session.includesSubfolders)
      .toggleStyle(.checkbox)
      .disabled(!isFolderScope)
      .help(isFolderScope ? "显示此目录及子目录中的图片" : "选择文件夹后可切换子目录范围")
  }

  private var isFolderScope: Bool {
    if case .folder = session.scope { return true }
    return false
  }

  private var filters: some View {
    HStack(spacing: 8) {
      Picker("图片范围", selection: $session.filter) {
        ForEach(RepositoryImageFilter.allCases) { Text($0.title).tag($0) }
      }
      .labelsHidden().frame(maxWidth: 120)
      .accessibilityIdentifier("repository-image-filter")
      Menu {
        Picker("排序方式", selection: $session.sortOrder) {
          ForEach(RepositoryImageSortOrder.allCases) { Text($0.title).tag($0) }
        }
      } label: {
        Text(session.sortOrder.shortTitle)
      }
      .fixedSize().disabled(session.scope == .recent)
      .accessibilityLabel("图片排序")
      .accessibilityIdentifier("repository-image-sort-menu")
    }
  }

  private var processMenu: some View {
    Menu {
      Text("仅处理所选图片对应的文章附件")
      ForEach(ImageWorkbenchBatchAction.allActions) { action in
        Button {
          onProcess(action)
        } label: {
          Label(action.title, systemImage: action.systemImage)
        }
      }
      Divider()
      Button("在 Finder 中显示") {
        NSWorkspace.shared.activateFileViewerSelecting(session.selectedAssets.map(\.fileURL))
      }
    } label: {
      Label("处理所选…", systemImage: "ellipsis")
    }
    .fixedSize().disabled(
      session.selectedPaths.isEmpty || isWorking || session.isLoading || session.isProjecting
    )
    .accessibilityIdentifier("repository-image-process-selection")
  }

  @ViewBuilder
  private var images: some View {
    if session.displayMode == .list {
      List(selection: $session.selectedPaths) {
        ForEach(session.visibleAssets) { asset in
          RepositoryImageGalleryRow(asset: asset).tag(asset.repositoryPath)
            .contextMenu { fileActions(asset) }
            .onTapGesture(count: 2) { session.previewURL = asset.fileURL }
        }
      }
      .listStyle(.inset).accessibilityLabel("仓库图片列表")
      .accessibilityIdentifier("repository-image-list")
      .onKeyPress(.space) {
        session.previewSelection()
        return .handled
      }
    } else {
      GeometryReader { geometry in
        let columns = max(1, Int((geometry.size.width - 40) / (session.thumbnailSize + 16)))
        ScrollView {
          LazyVGrid(
            columns: [GridItem(.adaptive(minimum: session.thumbnailSize), spacing: 16)],
            alignment: .leading, spacing: 18
          ) {
            ForEach(session.visibleAssets) { asset in
              Button {
                galleryFocused = true
                session.select(
                  asset.repositoryPath,
                  extending: NSEvent.modifierFlags.contains(.shift),
                  toggling: NSEvent.modifierFlags.contains(.command)
                )
              } label: {
                RepositoryImageGalleryTile(
                  asset: asset, isSelected: session.selectedPaths.contains(asset.repositoryPath),
                  thumbnailSize: session.thumbnailSize
                )
              }
              .buttonStyle(.plain)
              .id(asset.repositoryPath)
              .contextMenu { fileActions(asset) }
              .simultaneousGesture(
                TapGesture(count: 2).onEnded { session.previewURL = asset.fileURL }
              )
              .accessibilityLabel(asset.filename)
              .accessibilityAddTraits(
                session.selectedPaths.contains(asset.repositoryPath) ? .isSelected : []
              )
              .accessibilityIdentifier(
                "repository-image-tile-\(RepositoryAccessibilityIdentifier.token(for: asset.repositoryPath))"
              )
            }
          }
          .scrollTargetLayout()
          .padding(.horizontal, 20).padding(.bottom, 20)
        }
        .scrollPosition(id: $session.scrollAnchor)
        .focusable().focused($galleryFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
          let offset: Int
          switch direction {
          case .left: offset = -1
          case .right: offset = 1
          case .up: offset = -columns
          case .down: offset = columns
          @unknown default: return
          }
          session.moveSelection(by: offset, extending: NSEvent.modifierFlags.contains(.shift))
        }
        .onKeyPress(.space) {
          session.previewSelection()
          return .handled
        }
        .onKeyPress("a", phases: .down) { press in
          guard press.modifiers.contains(.command) else { return .ignored }
          session.selectedPaths = Set(session.visibleAssets.map(\.repositoryPath))
          return .handled
        }
      }
      .accessibilityLabel("仓库图片网格")
      .accessibilityIdentifier("repository-image-grid")
    }
  }

  private func fileActions(_ asset: RepositoryImageAsset) -> some View {
    Group {
      Button("预览") { session.previewURL = asset.fileURL }
      Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([asset.fileURL]) }
      Button("复制路径") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(asset.repositoryPath, forType: .string)
      }
    }
  }

  private var emptyState: some View {
    let hasFilters = !session.query.isEmpty || session.filter != .all
    return EmptyStateView(
      title: session.inventory?.assets.isEmpty == true
        ? "图片目录中还没有图片" : (hasFilters ? "没有匹配的仓库图片" : "当前范围中暂无图片"),
      message: hasFilters
        ? "选择其他文件夹，或清除搜索和筛选后重试。" : "可选择其他文件夹，或重新扫描以查看新加入的图片。",
      systemImage: "photo.on.rectangle", density: .compactPane,
      actionTitle: hasFilters ? "清除搜索和筛选" : nil,
      action: {
        session.query = ""
        session.filter = .all
      }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var statusBar: some View {
    HStack(spacing: 10) {
      if session.isLoading || session.isProjecting { ProgressView().controlSize(.small) }
      Text("\(session.visibleAssets.count) 张图片 · 已选择 \(session.selectedPaths.count) 张")
        .font(.workbenchSupporting).foregroundStyle(.secondary)
      Spacer(minLength: 8)
      if session.displayMode == .grid {
        Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
        Slider(value: $session.thumbnailSize, in: 140...300)
          .frame(width: 100).accessibilityLabel("缩略图大小")
        Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 10)
    .background(.bar)
  }

  nonisolated static func project(
    _ assets: [RepositoryImageAsset], query: String, filter: RepositoryImageFilter,
    sortOrder: RepositoryImageSortOrder
  ) -> [RepositoryImageAsset] {
    RepositoryImageBrowserProjection.project(
      assets, query: query, filter: filter, sortOrder: sortOrder)
  }
}
