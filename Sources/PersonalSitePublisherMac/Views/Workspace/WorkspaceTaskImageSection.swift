import AppKit
import PublishingDomainContracts
import PublishingWorkbenchCore
import SwiftUI

struct WorkspaceTaskImageState {
  let report: ImageWorkbenchReport?
  let actionMessage: String?
  let focusedAttachmentID: UUID?
}

struct WorkspaceTaskImageActions {
  let fillMissingMetadataForCurrentDraft: () -> Void
  let optimizeJPEGForCurrentDraft: () -> Void
  let openImageWorkbench: () -> Void
  let refreshReport: () -> Void
}

struct WorkspaceTaskImageSection: View {
  @WorkspaceModuleVisibilityStorage private var moduleVisibility
  @Binding var draft: ArticleDraft
  let state: WorkspaceTaskImageState
  let actions: WorkspaceTaskImageActions

  var body: some View {
    let report = state.report

    return VStack(alignment: .leading, spacing: 14) {
      InspectorSection("当前文章") {
        if let report {
          InspectorStatRow(title: "图片", value: "\(report.items.count)", systemImage: "photo")
          InspectorStatRow(
            title: "缺 alt", value: "\(report.missingAltTextCount)", systemImage: "text.quote")
          InspectorStatRow(
            title: "缺源图", value: "\(report.missingSourceCount)", systemImage: "xmark.octagon")
          InspectorStatRow(
            title: "可压缩 JPEG", value: "\(report.optimizableJPEGCount)",
            systemImage: "arrow.down.forward")
          Label(
            report.coverStatus.state.localizedDisplayName,
            systemImage: report.coverStatus.state.systemImage
          )
          .font(.caption)
          .foregroundStyle(report.coverStatus.state.color)
          .lineLimit(2)
        } else {
          ProgressView {
            Text("正在读取当前文章图片…")
          }
          .controlSize(.small)
        }
      }

      InspectorSection("图片元数据") {
        if draft.attachments.isEmpty {
          Text("当前文章还没有图片附件。")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          ForEach(draft.attachments) { attachment in
            ImageMetadataEditorRow(
              attachment: attachment,
              item: report?.items.first { $0.attachmentID == attachment.id },
              altText: attachmentStringBinding(for: attachment.id, keyPath: \.altText),
              caption: attachmentStringBinding(for: attachment.id, keyPath: \.caption),
              isCover: attachmentCoverBinding(for: attachment.id),
              isFocused: state.focusedAttachmentID == attachment.id
            )
            .id(attachment.id)
          }
        }
      }

      if moduleVisibility.imagesEnabled {
        InspectorSection("图片工作台") {
          Button {
            actions.openImageWorkbench()
          } label: {
            Label("打开图片工作台", systemImage: "photo.on.rectangle")
          }
          .controlSize(.small)
        }
      }

      actionMessage(state.actionMessage)
    }
  }

  private func attachmentStringBinding(
    for attachmentID: UUID,
    keyPath: WritableKeyPath<DraftAttachment, String>
  ) -> Binding<String> {
    Binding(
      get: {
        draft.attachments.first { $0.id == attachmentID }?[keyPath: keyPath] ?? ""
      },
      set: { value in
        guard let index = draft.attachments.firstIndex(where: { $0.id == attachmentID }) else {
          return
        }
        draft.attachments[index][keyPath: keyPath] = value
        actions.refreshReport()
      }
    )
  }

  private func attachmentCoverBinding(for attachmentID: UUID) -> Binding<Bool> {
    Binding(
      get: { draft.coverAttachmentID == attachmentID },
      set: { isCover in
        if isCover {
          draft.coverAttachmentID = attachmentID
        } else if draft.coverAttachmentID == attachmentID {
          draft.coverAttachmentID = nil
        }
        actions.refreshReport()
      }
    )
  }
}

private struct ImageMetadataEditorRow: View {
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  let attachment: DraftAttachment
  let item: ImageWorkbenchItem?
  @Binding var altText: String
  @Binding var caption: String
  @Binding var isCover: Bool
  let isFocused: Bool

  @FocusState private var isAltFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline) {
        Text(attachment.originalFilename)
          .font(.callout.weight(.medium))
          .workbenchTruncatedIdentity(attachment.originalFilename)

        if item?.isCover == true {
          Image(systemName: "star.fill")
            .foregroundStyle(.secondary)
        }

        Spacer()

        Image(systemName: item?.fileExists == false ? "xmark.octagon" : "checkmark.circle")
          .foregroundStyle(item?.fileExists == false ? WorkbenchTheme.risk : Color.secondary)
      }

      Text(attachment.relativePublishPath)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .workbenchTruncatedIdentity(attachment.relativePublishPath, lineLimit: 2)

      TextField("Alt", text: $altText)
        .textFieldStyle(.roundedBorder)
        .focused($isAltFocused)
        .accessibilityLabel("图片 Alt 文本")
        .accessibilityValue(altText.isEmpty ? String(localized: "未填写") : altText)

      TextField("Caption", text: $caption)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("图片 Caption")
        .accessibilityValue(caption.isEmpty ? String(localized: "未填写") : caption)

      Toggle("设为文章封面", isOn: $isCover)
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }
    .padding(8)
    .background(
      isFocused ? workbenchAccentColor.opacity(0.10) : Color.clear,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .overlay {
      if isFocused {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .stroke(workbenchAccentColor.opacity(0.45), lineWidth: 1)
      }
    }
    .onAppear {
      if isFocused {
        isAltFocused = true
      }
    }
    .onChange(of: isFocused) { _, shouldFocus in
      if shouldFocus {
        isAltFocused = true
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片元数据 \(attachment.originalFilename)")
    .accessibilityValue(item?.fileExists == false ? "源图缺失" : "源图可用")
  }
}
