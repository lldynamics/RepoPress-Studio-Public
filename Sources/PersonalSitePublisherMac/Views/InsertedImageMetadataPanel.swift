import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct InsertedImageMetadataDraft: Identifiable, Equatable {
  let id: UUID
  let filename: String
  var altText: String
  var caption: String
  var isCover: Bool

  init(attachment: DraftAttachment, coverAttachmentID: UUID?) {
    id = attachment.id
    filename = attachment.originalFilename
    altText = attachment.altText
    caption = attachment.caption
    isCover = coverAttachmentID == attachment.id
  }
}

struct InsertedImageMetadataPanel: View {
  @Binding var metadata: InsertedImageMetadataDraft
  let position: Int
  let total: Int
  let canMovePrevious: Bool
  let canMoveNext: Bool
  let onSetCover: (Bool) -> Void
  let onMovePrevious: () -> Void
  let onApplyAndAdvance: () -> Void
  let onOpenInspector: () -> Void
  let onDismiss: () -> Void

  @FocusState private var focusedField: Field?

  private enum Field {
    case alt
    case caption
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header

      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(metadata.filename)
          .font(.callout.weight(.medium))
          .workbenchTruncatedIdentity(metadata.filename)

        Spacer(minLength: 8)

        if total > 1 {
          Text("图片 \(position) / \(total)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }

      TextField(text: $metadata.altText) {
        Text("Alt 文本")
      }
        .textFieldStyle(.roundedBorder)
        .focused($focusedField, equals: .alt)
        .accessibilityLabel(Text("图片 Alt 文本"))

      TextField(text: $metadata.caption) {
        Text("Caption（可选）")
      }
        .textFieldStyle(.roundedBorder)
        .focused($focusedField, equals: .caption)
        .accessibilityLabel(Text("图片 Caption"))

      HStack(spacing: 10) {
        Toggle(
          isOn: Binding(
            get: { metadata.isCover },
            set: { isCover in
              onSetCover(isCover)
            }
          )
        ) {
          Text("设为文章封面")
        }
        .toggleStyle(.checkbox)

        Spacer(minLength: 8)

        Text("高级压缩保留在图片工作台。")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }

      footer
    }
    .padding(12)
    .frame(maxWidth: 620)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55))
    }
    .onAppear {
      focusedField = .alt
    }
    .onChange(of: metadata.id) { _, _ in
      focusedField = .alt
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text("插入后完善图片"))
  }

  private var header: some View {
    HStack(spacing: 8) {
      Label {
        Text("完善图片")
      } icon: {
        Image(systemName: "photo.badge.checkmark")
      }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      Spacer()

      Button {
        onDismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help("稍后完善")
      .accessibilityLabel(Text("稍后完善图片"))
    }
  }

  private var footer: some View {
    HStack(spacing: 8) {
      if total > 1 {
        Button {
          onMovePrevious()
        } label: {
          Label {
            Text("上一张")
          } icon: {
            Image(systemName: "chevron.left")
          }
        }
        .disabled(!canMovePrevious)
      }

      Button {
        onOpenInspector()
      } label: {
        Label {
          Text("前往图片 Inspector")
        } icon: {
          Image(systemName: "sidebar.right")
        }
      }

      Spacer(minLength: 8)

      Button {
        onDismiss()
      } label: {
        Text("稍后")
      }

      Button {
        onApplyAndAdvance()
      } label: {
        if canMoveNext {
          Label {
            Text("保存并下一张")
          } icon: {
            Image(systemName: "arrow.right.circle")
          }
        } else {
          Label {
            Text("完成")
          } icon: {
            Image(systemName: "checkmark.circle")
          }
        }
      }
      .workbenchProminentActionStyle()
      .keyboardShortcut(.return, modifiers: [.command])
    }
    .controlSize(.small)
  }
}
