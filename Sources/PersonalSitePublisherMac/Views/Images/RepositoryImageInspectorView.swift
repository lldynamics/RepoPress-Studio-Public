import AppKit
import Foundation
import PublishingDomainContracts
import SwiftUI

struct RepositoryImageInspectorView: View {
  private enum Tab: String, CaseIterable, Identifiable {
    case fileInfo
    case articleUsage

    var id: Self { self }

    var title: String {
      switch self {
      case .fileInfo: String(localized: "文件信息")
      case .articleUsage: String(localized: "文章用法")
      }
    }
  }

  let asset: RepositoryImageAsset
  let dimensionsText: String?
  let availableDrafts: [RepositoryImageTargetDraft]
  @Binding var targetDraftID: UUID?
  let usage: RepositoryImageArticleUsage?
  let isWorking: Bool
  let saveStatusText: String?
  let saveStatusIsError: Bool
  let onEditAlt: (String) -> Void
  let onEditCaption: (String) -> Void
  let onSetCover: (Bool) -> Void
  let onFillMetadata: () -> Void
  let onAttach: (UUID) -> Void
  let onOpenDraft: (UUID) -> Void
  let onPreview: () -> Void

  @State private var selectedTab: Tab

  init(
    asset: RepositoryImageAsset,
    dimensionsText: String?,
    availableDrafts: [RepositoryImageTargetDraft],
    targetDraftID: Binding<UUID?>,
    usage: RepositoryImageArticleUsage?,
    isWorking: Bool,
    saveStatusText: String?,
    saveStatusIsError: Bool,
    onEditAlt: @escaping (String) -> Void,
    onEditCaption: @escaping (String) -> Void,
    onSetCover: @escaping (Bool) -> Void,
    onFillMetadata: @escaping () -> Void,
    onAttach: @escaping (UUID) -> Void,
    onOpenDraft: @escaping (UUID) -> Void,
    onPreview: @escaping () -> Void
  ) {
    self.asset = asset
    self.dimensionsText = dimensionsText
    self.availableDrafts = availableDrafts
    _targetDraftID = targetDraftID
    self.usage = usage
    self.isWorking = isWorking
    self.saveStatusText = saveStatusText
    self.saveStatusIsError = saveStatusIsError
    self.onEditAlt = onEditAlt
    self.onEditCaption = onEditCaption
    self.onSetCover = onSetCover
    self.onFillMetadata = onFillMetadata
    self.onAttach = onAttach
    self.onOpenDraft = onOpenDraft
    self.onPreview = onPreview
    _selectedTab = State(initialValue: usage == nil ? .fileInfo : .articleUsage)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        previewHeader
        picker
        selectedTabContent
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: asset.repositoryPath) { _, _ in
      selectedTab = usage == nil ? .fileInfo : .articleUsage
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(String(localized: "选中的仓库图片"))
    .accessibilityIdentifier("repository-image-inspector")
  }

  private var previewHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      WorkbenchThumbnailView(fileURL: asset.fileURL, maxPixelSize: 512, cornerRadius: 8)
        .frame(maxWidth: .infinity, minHeight: 140, idealHeight: 170, maxHeight: 180)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)

      Text(asset.filename)
        .font(.headline)
        .workbenchTruncatedIdentity(asset.filename, lineLimit: 2)

      Text(fileSummary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .workbenchTruncatedIdentity(fileSummary, lineLimit: 2)

      HStack(spacing: 8) {
        Button {
          onPreview()
        } label: {
          Label(String(localized: "预览"), systemImage: "eye")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("repository-image-preview")

        Button {
          NSWorkspace.shared.activateFileViewerSelecting([asset.fileURL])
        } label: {
          Label(String(localized: "Finder"), systemImage: "folder")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("repository-image-reveal")
      }
      .controlSize(.small)
    }
  }

  private var picker: some View {
    Picker(String(localized: "检查器内容"), selection: $selectedTab) {
      ForEach(Tab.allCases) { tab in
        Text(tab.title).tag(tab)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .accessibilityLabel(String(localized: "图片检查器内容"))
    .accessibilityIdentifier("repository-image-inspector-tabs")
  }

  @ViewBuilder
  private var selectedTabContent: some View {
    switch selectedTab {
    case .fileInfo:
      fileInfo
    case .articleUsage:
      RepositoryImageInspectorUsageView(
        asset: asset,
        availableDrafts: availableDrafts,
        targetDraftID: $targetDraftID,
        usage: usage,
        isWorking: isWorking,
        saveStatusText: saveStatusText,
        saveStatusIsError: saveStatusIsError,
        onEditAlt: onEditAlt,
        onEditCaption: onEditCaption,
        onSetCover: onSetCover,
        onFillMetadata: onFillMetadata,
        onAttach: onAttach,
        onOpenDraft: onOpenDraft
      )
    }
  }

  private var fileInfo: some View {
    VStack(alignment: .leading, spacing: 10) {
      Group {
        LabeledContent(String(localized: "格式"), value: asset.fileExtension.uppercased())
        LabeledContent(
          String(localized: "文件大小"),
          value: ByteCountFormatter.string(fromByteCount: asset.byteSize, countStyle: .file)
        )
        if let dimensionsText, !dimensionsText.isEmpty {
          LabeledContent(String(localized: "尺寸"), value: dimensionsText)
        }
        if let modifiedAt = asset.modifiedAt {
          LabeledContent(
            String(localized: "修改时间"),
            value: modifiedAt.formatted(date: .abbreviated, time: .shortened)
          )
        }
        LabeledContent(String(localized: "引用文章"), value: "\(asset.references.count)")
      }
      .font(.callout)

      VStack(alignment: .leading, spacing: 4) {
        Text(String(localized: "完整路径"))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(asset.absoluteFilePath)
          .font(.caption.monospaced())
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .workbenchTruncatedIdentity(asset.absoluteFilePath, lineLimit: 4)
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(asset.repositoryPath, forType: .string)
        } label: {
          Label(String(localized: "复制仓库路径"), systemImage: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .accessibilityIdentifier("repository-image-copy-path")
      }

      if !asset.references.isEmpty {
        Divider()
        Text(String(localized: "已登记到"))
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        ForEach(asset.references, id: \.self) { reference in
          Button {
            onOpenDraft(reference.draftID)
          } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
              Image(systemName: reference.isCover ? "star.fill" : "doc.text")
                .frame(width: 14)
                .accessibilityHidden(true)
              Text(reference.draftTitle)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
              Spacer(minLength: 4)
              Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
          }
          .buttonStyle(.borderless)
          .accessibilityIdentifier("repository-image-open-article-\(reference.draftID.uuidString)")
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(String(localized: "图片文件信息"))
    .accessibilityIdentifier("repository-image-file-info")
  }

  private var fileSummary: String {
    var parts = [asset.fileExtension.uppercased()]
    if let dimensionsText, !dimensionsText.isEmpty {
      parts.append(dimensionsText)
    }
    parts.append(ByteCountFormatter.string(fromByteCount: asset.byteSize, countStyle: .file))
    return parts.joined(separator: " · ")
  }
}
