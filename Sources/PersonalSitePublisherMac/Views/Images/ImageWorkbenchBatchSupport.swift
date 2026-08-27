import PublishingWorkbenchCore
import SwiftUI

enum ImageWorkbenchBatchAction: Identifiable {
  case fillMetadata
  case file(ImageBatchOperation)

  static let allActions: [ImageWorkbenchBatchAction] = [
    .fillMetadata,
    .file(.optimizeJPEG),
    .file(.convertWebP),
    .file(.optimizeSVG),
    .file(.resizeLargeImages),
  ]

  var id: String {
    switch self {
    case .fillMetadata: "fill-metadata"
    case .file(.optimizeJPEG): "optimize-jpeg"
    case .file(.convertWebP): "convert-webp"
    case .file(.optimizeSVG): "optimize-svg"
    case .file(.resizeLargeImages): "resize-large-images"
    case .file(.cropCover16By9): "crop-cover-16-9"
    }
  }

  var title: String {
    switch self {
    case .fillMetadata: String(localized: "补全 alt/caption")
    case .file(let operation): operation.progressTitle
    }
  }

  var shortDescription: String {
    switch self {
    case .fillMetadata: String(localized: "填写缺失的替代文本和图片说明")
    case .file(.optimizeJPEG): String(localized: "减小 JPEG 文件体积")
    case .file(.convertWebP): String(localized: "生成 WebP 并更新文章引用")
    case .file(.optimizeSVG): String(localized: "精简 SVG 中的冗余内容")
    case .file(.resizeLargeImages): String(localized: "缩小超过建议尺寸的图片")
    case .file(.cropCover16By9): String(localized: "生成适合社交分享的封面副本")
    }
  }

  var isMetadataFill: Bool {
    if case .fillMetadata = self { return true }
    return false
  }

  var systemImage: String {
    switch self {
    case .fillMetadata: "text.badge.checkmark"
    case .file(.optimizeJPEG): "photo.stack"
    case .file(.convertWebP): "arrow.triangle.2.circlepath"
    case .file(.optimizeSVG): "wand.and.stars"
    case .file(.resizeLargeImages): "arrow.down.right.and.arrow.up.left"
    case .file(.cropCover16By9): "crop"
    }
  }

  var accessibilityIdentifier: String {
    "image-action-\(id)"
  }

  var outputDescription: String {
    switch self {
    case .fillMetadata:
      return String(localized: "补全所选图片缺失的 alt 和 caption，并同步正文中的空图片替代文本。")
    case .file(.optimizeJPEG):
      return String(localized: "生成优化后的 JPEG 副本，保留 JPEG 格式。")
    case .file(.convertWebP):
      return String(localized: "生成 WebP 副本，并把草稿图片引用更新为 WebP。")
    case .file(.optimizeSVG):
      return String(localized: "生成精简后的 SVG 副本，保留 SVG 格式。")
    case .file(.resizeLargeImages):
      return String(localized: "按原格式生成缩小尺寸的图片副本。")
    case .file(.cropCover16By9):
      return String(localized: "生成 16:9 的封面副本。")
    }
  }

  var estimatedSavingRatio: Double {
    switch self {
    case .fillMetadata: 0
    case .file(.optimizeJPEG): 0.18
    case .file(.convertWebP): 0.28
    case .file(.optimizeSVG): 0.12
    case .file(.resizeLargeImages): 0.35
    case .file(.cropCover16By9): 0.20
    }
  }

  func targetCount(in summary: ImageWorkbenchSiteSummary) -> Int {
    switch self {
    case .fillMetadata:
      summary.draftSummaries.reduce(0) { result, draft in
        result + draft.items.filter { $0.missingAltText || $0.missingCaption }.count
      }
    case .file(.optimizeJPEG): summary.optimizableJPEGCount
    case .file(.convertWebP): summary.webPConvertibleCount
    case .file(.optimizeSVG): summary.optimizableSVGCount
    case .file(.resizeLargeImages): summary.resizableImageCount
    case .file(.cropCover16By9): 0
    }
  }

  func includes(_ item: ImageWorkbenchItem) -> Bool {
    switch self {
    case .fillMetadata:
      return item.missingAltText || item.missingCaption
    case .file(.optimizeJPEG):
      return item.canOptimizeJPEG
    case .file(.convertWebP):
      return item.canConvertToWebP
    case .file(.optimizeSVG):
      return item.canOptimizeSVG
    case .file(.resizeLargeImages):
      return item.canResizeImage
    case .file(.cropCover16By9):
      return item.isCover
    }
  }
}

struct ImageBatchAffectedItemID: Hashable {
  let draftID: UUID
  let attachmentID: UUID
}

struct ImageBatchAffectedItem: Identifiable {
  let draftID: UUID
  let draftTitle: String
  let item: ImageWorkbenchItem

  var id: ImageBatchAffectedItemID {
    ImageBatchAffectedItemID(draftID: draftID, attachmentID: item.attachmentID)
  }

  var detail: String {
    var parts: [String] = []
    if item.missingAltText { parts.append(String(localized: "缺 alt")) }
    if item.missingCaption { parts.append(String(localized: "缺 caption")) }
    if item.byteSize > 0 {
      parts.append(ByteCountFormatter.string(fromByteCount: item.byteSize, countStyle: .file))
    }
    if let dimensions = item.dimensions {
      parts.append("\(dimensions.width)×\(dimensions.height)")
    }
    return parts.joined(separator: " · ")
  }
}

struct ImageBatchOperationPreview: Identifiable {
  let id = UUID()
  let action: ImageWorkbenchBatchAction
  let affectedItems: [ImageBatchAffectedItem]
}

struct ImageBatchOperationPreviewView: View {
  let preview: ImageBatchOperationPreview
  let cancel: () -> Void
  let confirm: ([UUID: Set<UUID>]) -> Void
  @State private var selectedItemIDs: Set<ImageBatchAffectedItemID>

  init(
    preview: ImageBatchOperationPreview,
    cancel: @escaping () -> Void,
    confirm: @escaping ([UUID: Set<UUID>]) -> Void
  ) {
    self.preview = preview
    self.cancel = cancel
    self.confirm = confirm
    _selectedItemIDs = State(initialValue: Set(preview.affectedItems.map(\.id)))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Label(
          String(format: String(localized: "确认%@"), preview.action.title),
          systemImage: preview.action.systemImage
        )
          .font(.title3.weight(.semibold))
        Text("逐项核对影响文章和图片；取消勾选即可排除单张图片。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
        MetricTile(title: "影响文章", value: "\(selectedDraftCount)", systemImage: "doc.text")
        MetricTile(title: "影响图片", value: "\(selectedItems.count)", systemImage: "photo.on.rectangle")
        MetricTile(
          title: preview.action.isMetadataFill ? "待补字段" : "预计节省",
          value: preview.action.isMetadataFill
            ? "\(selectedMetadataFieldCount)"
            : ByteCountFormatter.string(fromByteCount: estimatedSavedBytes, countStyle: .file),
          systemImage: preview.action.isMetadataFill ? "textformat" : "arrow.down.circle"
        )
      }

      HStack {
        Text("影响明细")
          .font(.headline)
        Spacer()
        Button("全选") {
          selectedItemIDs = Set(preview.affectedItems.map(\.id))
        }
        .disabled(selectedItemIDs.count == preview.affectedItems.count)
        Button("全部排除") {
          selectedItemIDs.removeAll()
        }
        .disabled(selectedItemIDs.isEmpty)
      }

      List(preview.affectedItems) { affected in
        Toggle(isOn: selectionBinding(for: affected.id)) {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "photo")
              .foregroundStyle(.secondary)
              .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
              Text(affected.item.originalFilename)
                .font(.callout.weight(.medium))
                .workbenchTruncatedIdentity(affected.item.originalFilename)
              Text(affected.draftTitle)
                .font(.workbenchSupporting)
                .foregroundStyle(.secondary)
                .workbenchTruncatedIdentity(affected.draftTitle)
              if !affected.detail.isEmpty {
                Text(affected.detail)
                  .font(.workbenchSupporting)
                  .foregroundStyle(.tertiary)
              }
            }
          }
        }
        .toggleStyle(.checkbox)
      }
      .frame(minHeight: 230, idealHeight: 300)

      GroupBox(String(localized: "输出与恢复")) {
        VStack(alignment: .leading, spacing: 6) {
          Text(preview.action.outputDescription)
          Label("开始前会为每篇受影响文章创建“批处理前”版本点。", systemImage: "clock.arrow.circlepath")
          Label("文件处理期间可以取消；未应用的临时文件会被清理。", systemImage: "xmark.circle")
        }
        .font(.workbenchSupporting)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        Button("取消", action: cancel)
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button {
          confirm(selectionByDraft)
        } label: {
          Label(
            String(format: String(localized: "确认并开始（%d 张）"), selectedItems.count),
            systemImage: "play.fill"
          )
        }
        .workbenchProminentActionStyle()
        .keyboardShortcut(.defaultAction)
        .disabled(selectedItemIDs.isEmpty)
      }
    }
    .padding(22)
    .frame(minWidth: 640, idealWidth: 720, minHeight: 620, idealHeight: 720)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片批处理影响预览")
  }

  private var selectedItems: [ImageBatchAffectedItem] {
    preview.affectedItems.filter { selectedItemIDs.contains($0.id) }
  }

  private var selectedDraftCount: Int {
    Set(selectedItems.map(\.draftID)).count
  }

  private var selectedMetadataFieldCount: Int {
    selectedItems.reduce(0) { count, affected in
      count + (affected.item.missingAltText ? 1 : 0) + (affected.item.missingCaption ? 1 : 0)
    }
  }

  private var estimatedSavedBytes: Int64 {
    let selectedBytes = selectedItems.reduce(Int64(0)) { $0 + max(0, $1.item.byteSize) }
    return Int64(Double(selectedBytes) * preview.action.estimatedSavingRatio)
  }

  private var selectionByDraft: [UUID: Set<UUID>] {
    Dictionary(grouping: selectedItems, by: \.draftID)
      .mapValues { Set($0.map(\.item.attachmentID)) }
  }

  private func selectionBinding(for itemID: ImageBatchAffectedItemID) -> Binding<Bool> {
    Binding(
      get: { selectedItemIDs.contains(itemID) },
      set: { isSelected in
        if isSelected {
          selectedItemIDs.insert(itemID)
        } else {
          selectedItemIDs.remove(itemID)
        }
      }
    )
  }
}
