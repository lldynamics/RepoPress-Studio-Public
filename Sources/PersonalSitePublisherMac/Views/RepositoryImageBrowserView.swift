import AppKit
import PublishingWorkbenchCore
import SwiftUI

enum RepositoryImageFilter: String, CaseIterable, Identifiable {
  case all
  case registered
  case unregistered

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: String(localized: "全部")
    case .registered: String(localized: "已登记")
    case .unregistered: String(localized: "未登记")
    }
  }

  func includes(_ asset: RepositoryImageAsset) -> Bool {
    switch self {
    case .all: true
    case .registered: asset.isRegisteredToArticle
    case .unregistered: !asset.isRegisteredToArticle
    }
  }
}

struct RepositoryImageBrowserView: View {
  let inventory: RepositoryImageInventory?
  let isLoading: Bool
  let errorMessage: String?
  let targetDrafts: [ArticleDraft]
  @Binding var targetDraftID: UUID?
  @Binding var selectedRepositoryPath: String?
  let onAttachToSelectedDraft: (RepositoryImageAsset) -> Void
  let onOpenReferencedDraft: (UUID) -> Void
  let onOpenRepositorySettings: () -> Void

  @State private var query = ""
  @State private var filter: RepositoryImageFilter = .all

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header

      if isLoading, inventory == nil {
        loadingState
      } else if let inventory {
        inventoryContent(inventory)
      } else if let errorMessage {
        failureState(errorMessage)
      } else {
        loadingState
      }
    }
    .padding(14)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("仓库图片")
    .accessibilityIdentifier("repository-image-browser")
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Label("仓库图片", systemImage: "externaldrive")
          .font(.headline)
        Text("浏览图片目录中的实际文件，查看引用文章，或把现有图片加入目标文章。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if isLoading {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("正在刷新仓库图片")
      }
    }
  }

  private func inventoryContent(_ inventory: RepositoryImageInventory) -> some View {
    let filteredAssets = filteredAssets(inventory)
    return VStack(alignment: .leading, spacing: 12) {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
        MetricTile(title: "仓库图片", value: "\(inventory.assets.count)", systemImage: "photo.stack")
        MetricTile(title: "已登记", value: "\(inventory.registeredCount)", systemImage: "link")
        MetricTile(title: "未登记", value: "\(inventory.unregisteredCount)", systemImage: "questionmark.folder")
        MetricTile(
          title: "总体积",
          value: ByteCountFormatter.string(fromByteCount: inventory.totalByteSize, countStyle: .file),
          systemImage: "internaldrive"
        )
      }

      if inventory.wasTruncated {
        Label("图片过多，当前只显示前 5,000 张。可以通过 Finder 继续管理。", systemImage: "exclamationmark.triangle")
          .font(.workbenchSupporting)
          .foregroundStyle(WorkbenchTheme.warning)
      }

      targetArticleControls

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 10) {
          searchField
          filterPicker
        }
        VStack(alignment: .leading, spacing: 8) {
          searchField
          filterPicker
        }
      }

      if filteredAssets.isEmpty {
        EmptyStateView(
          title: query.trimmedForPublishing.isEmpty ? "图片目录中还没有图片" : "没有匹配的仓库图片",
          message: query.trimmedForPublishing.isEmpty
            ? "在写作页插入图片，或把图片文件放入当前站点的图片目录。"
            : "请尝试其他文件名、路径或筛选范围。",
          systemImage: "photo.on.rectangle.angled",
          density: .compactPane
        )
      } else {
        browserLayout(inventory, assets: filteredAssets)
      }

      Text("“未登记”只表示已载入文章的附件列表中没有该图片；主题、CSS 或其他文件仍可能引用它。")
        .font(.workbenchSupporting)
        .foregroundStyle(.tertiary)
    }
    .onAppear { normalizeSelection(in: inventory) }
    .onChange(of: query) { _, _ in normalizeSelection(in: inventory) }
    .onChange(of: filter) { _, _ in normalizeSelection(in: inventory) }
    .onChange(of: inventory.revisionID) { _, _ in normalizeSelection(in: inventory) }
  }

  private var targetArticleControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 7) {
        Image(systemName: "doc.badge.plus")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text("加入文章")
          .font(.callout.weight(.semibold))
      }
      Text("先选择当前站点的目标文章，再把仓库现有图片加入它的图片列表。")
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          targetArticlePicker
          openTargetArticleButton
        }
        VStack(alignment: .leading, spacing: 8) {
          targetArticlePicker
          openTargetArticleButton
        }
      }
    }
    .padding(10)
    .background(
      WorkbenchBackgroundStyle.control,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("仓库图片的目标文章")
  }

  private var targetArticlePicker: some View {
    Picker("目标文章", selection: $targetDraftID) {
      if targetDrafts.isEmpty {
        Text("当前站点还没有文章")
          .tag(nil as UUID?)
      } else {
        ForEach(targetDrafts) { draft in
          Text(draft.title.trimmedForPublishing.nilIfEmpty ?? String(localized: "未命名文章"))
            .tag(Optional(draft.id))
        }
      }
    }
    .frame(maxWidth: 420)
    .accessibilityIdentifier("repository-image-target-picker")
  }

  private var openTargetArticleButton: some View {
    Button {
      if let targetDraftID {
        onOpenReferencedDraft(targetDraftID)
      }
    } label: {
      Label("打开目标文章", systemImage: "arrow.right.circle")
    }
    .buttonStyle(.bordered)
    .disabled(targetDraft(in: targetDrafts) == nil)
    .accessibilityIdentifier("repository-image-open-target-article")
  }

  private func browserLayout(
    _ inventory: RepositoryImageInventory,
    assets: [RepositoryImageAsset]
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 14) {
        assetList(assets)
          .frame(minWidth: 420, maxWidth: .infinity)
        assetDetail(inventory, assets: assets)
          .frame(width: 340)
      }
      VStack(alignment: .leading, spacing: 14) {
        assetList(assets)
        assetDetail(inventory, assets: assets)
      }
    }
  }

  private func assetList(_ assets: [RepositoryImageAsset]) -> some View {
    List(selection: $selectedRepositoryPath) {
      ForEach(assets) { asset in
        RepositoryImageRow(asset: asset)
          .tag(asset.repositoryPath)
          .accessibilityIdentifier(
            "repository-image-row-\(RepositoryAccessibilityIdentifier.token(for: asset.repositoryPath))"
          )
      }
    }
    .listStyle(.inset)
    .frame(minHeight: 300, idealHeight: 380, maxHeight: 440)
    .accessibilityLabel("仓库图片列表")
    .accessibilityIdentifier("repository-image-list")
  }

  @ViewBuilder
  private func assetDetail(
    _ inventory: RepositoryImageInventory,
    assets: [RepositoryImageAsset]
  ) -> some View {
    if let asset = selectedAsset(in: assets) {
      VStack(alignment: .leading, spacing: 10) {
        WorkbenchThumbnailView(fileURL: asset.fileURL, maxPixelSize: 512, cornerRadius: 10)
          .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 180)
          .background(
            WorkbenchBackgroundStyle.control,
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          )
          .accessibilityHidden(true)

        Text(asset.filename)
          .font(.callout.weight(.semibold))
          .workbenchTruncatedIdentity(asset.filename, lineLimit: 2)
        Text(asset.repositoryPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .workbenchTruncatedIdentity(asset.repositoryPath, lineLimit: 3)

        LabeledContent("格式", value: asset.fileExtension)
        LabeledContent("文件大小", value: ByteCountFormatter.string(fromByteCount: asset.byteSize, countStyle: .file))
        LabeledContent("引用文章", value: "\(asset.references.count)")
        if let modifiedAt = asset.modifiedAt {
          LabeledContent(
            "修改时间",
            value: modifiedAt.formatted(date: .abbreviated, time: .shortened)
          )
        }

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 88), spacing: 8)],
          alignment: .leading,
          spacing: 8
        ) {
          Button {
            NSWorkspace.shared.open(asset.fileURL)
          } label: {
            Label("预览", systemImage: "eye")
          }
          .accessibilityIdentifier("repository-image-preview")
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([asset.fileURL])
          } label: {
            Label("Finder", systemImage: "folder")
          }
          .accessibilityIdentifier("repository-image-reveal")
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(asset.repositoryPath, forType: .string)
          } label: {
            Label("复制路径", systemImage: "doc.on.doc")
          }
          .accessibilityIdentifier("repository-image-copy-path")
        }
        .controlSize(.small)

        Button {
          onAttachToSelectedDraft(asset)
        } label: {
          Label(attachButtonTitle(asset), systemImage: "plus.circle")
            .frame(maxWidth: .infinity)
        }
        .workbenchProminentActionStyle()
        .disabled(!canAttach(asset))
        .help(attachHelp(asset))
        .accessibilityIdentifier("repository-image-attach")

        if !asset.references.isEmpty {
          Divider()
          Text("已登记到")
            .font(.caption.weight(.semibold))
          ForEach(asset.references, id: \.self) { reference in
            Button {
              onOpenReferencedDraft(reference.draftID)
            } label: {
              HStack(spacing: 7) {
                Image(systemName: reference.isCover ? "star.fill" : "doc.text")
                  .frame(width: 14)
                Text(reference.draftTitle)
                  .lineLimit(1)
                Spacer()
                Text("打开")
                  .font(.caption)
              }
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("repository-image-open-article-\(reference.draftID.uuidString)")
          }
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        WorkbenchBackgroundStyle.control,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
      .accessibilityElement(children: .contain)
      .accessibilityLabel("选中的仓库图片")
      .accessibilityIdentifier("repository-image-detail")
    }
  }

  private var loadingState: some View {
    HStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text("正在读取仓库图片…")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
  }

  private func failureState(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("暂时无法读取仓库图片", systemImage: "folder.badge.questionmark")
        .font(.callout.weight(.semibold))
      Text(message)
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      Button {
        onOpenRepositorySettings()
      } label: {
        Label("打开仓库与发布", systemImage: "arrow.triangle.2.circlepath")
      }
    }
    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
  }

  private func filteredAssets(_ inventory: RepositoryImageInventory) -> [RepositoryImageAsset] {
    let normalizedQuery = query.trimmedForPublishing
    return inventory.assets.filter { asset in
      filter.includes(asset)
        && (normalizedQuery.isEmpty
          || asset.filename.localizedStandardContains(normalizedQuery)
          || asset.repositoryPath.localizedStandardContains(normalizedQuery))
    }
  }

  private var searchField: some View {
    TextField("搜索文件名或仓库路径", text: $query)
      .textFieldStyle(.roundedBorder)
      .accessibilityLabel("搜索仓库图片")
      .accessibilityIdentifier("repository-image-search")
  }

  private var filterPicker: some View {
    Picker("图片范围", selection: $filter) {
      ForEach(RepositoryImageFilter.allCases) { option in
        Text(option.title).tag(option)
      }
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: 260)
    .accessibilityIdentifier("repository-image-filter")
  }

  private func selectedAsset(in assets: [RepositoryImageAsset]) -> RepositoryImageAsset? {
    if let selectedRepositoryPath,
       let selected = assets.first(where: { $0.repositoryPath == selectedRepositoryPath }) {
      return selected
    }
    return assets.first
  }

  private func normalizeSelection(in inventory: RepositoryImageInventory) {
    let assets = filteredAssets(inventory)
    if let selectedRepositoryPath,
       assets.contains(where: { $0.repositoryPath == selectedRepositoryPath }) {
      return
    }
    selectedRepositoryPath = assets.first?.repositoryPath
  }

  private func canAttach(_ asset: RepositoryImageAsset) -> Bool {
    guard let targetDraftID,
          targetDrafts.contains(where: { $0.id == targetDraftID }) else { return false }
    return !asset.references.contains(where: { $0.draftID == targetDraftID })
  }

  private func attachButtonTitle(_ asset: RepositoryImageAsset) -> String {
    guard let targetDraftID,
          targetDrafts.contains(where: { $0.id == targetDraftID }) else {
      return String(localized: "请先选择文章")
    }
    if asset.references.contains(where: { $0.draftID == targetDraftID }) {
      return String(localized: "已在目标文章中")
    }
    return String(localized: "加入目标文章")
  }

  private func attachHelp(_ asset: RepositoryImageAsset) -> String {
    guard let targetDraftID,
          let targetDraft = targetDrafts.first(where: { $0.id == targetDraftID }) else {
      return String(localized: "请先选择当前站点的目标文章。")
    }
    if asset.references.contains(where: { $0.draftID == targetDraftID }) {
      return String(localized: "该图片已在目标文章的图片列表中。")
    }
    let title = targetDraft.title.trimmedForPublishing.nilIfEmpty ?? String(localized: "当前文章")
    return String(format: String(localized: "把这张图片加入“%@”的图片列表。"), title)
  }

  private func targetDraft(in drafts: [ArticleDraft]) -> ArticleDraft? {
    guard let targetDraftID else { return nil }
    return drafts.first(where: { $0.id == targetDraftID })
  }
}

private struct RepositoryImageRow: View {
  let asset: RepositoryImageAsset

  var body: some View {
    HStack(spacing: 10) {
      WorkbenchThumbnailView(fileURL: asset.fileURL, maxPixelSize: 96, cornerRadius: 6)
        .frame(width: 36, height: 36)

      VStack(alignment: .leading, spacing: 2) {
        Text(asset.filename)
          .font(.body.weight(.medium))
          .lineLimit(1)
        Text(asset.repositoryPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        Text(ByteCountFormatter.string(fromByteCount: asset.byteSize, countStyle: .file))
          .font(.caption.monospacedDigit())
        Text(
          asset.isRegisteredToArticle
            ? String(format: String(localized: "已登记 %d"), asset.references.count)
            : String(localized: "未登记")
        )
          .font(.caption)
          .foregroundStyle(asset.isRegisteredToArticle ? Color.secondary : WorkbenchTheme.warning)
      }
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(asset.filename)
    .accessibilityValue(
      asset.isRegisteredToArticle
        ? String(format: String(localized: "已登记到 %d 篇文章"), asset.references.count)
        : String(localized: "未登记到已载入文章")
    )
  }
}
