import PublishingDomainContracts
import SwiftUI

/// A popover keeps the attachment checklist open while the user makes several
/// selections. A menu closes after every button activation, which makes a
/// multi-image choice needlessly repetitive with a pointer.
struct AIChatImageAttachmentPicker: View {
  let attachments: [DraftAttachment]
  let selectedIDs: Set<UUID>
  let onToggle: (UUID) -> Void
  let onClear: () -> Void
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented = true
    } label: {
      Label(
        selectedIDs.isEmpty
          ? String(localized: "添加图片")
          : String(localized: "图片 \(selectedIDs.count)"),
        systemImage: "paperclip"
      )
    }
    .buttonStyle(.borderless)
    .fixedSize()
    .accessibilityIdentifier("ai-chat-image-attachment-picker")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 10) {
        Text("添加图片")
          .font(.workbenchHeadline)

        if attachments.isEmpty {
          Text("当前文章没有可发送的图片")
            .foregroundStyle(.workbenchSecondary)
        } else {
          ScrollView {
            VStack(alignment: .leading, spacing: 8) {
              ForEach(attachments) { attachment in
                let knownFailureReason = AIChatImageAttachmentSelectionPolicy.knownFailureReason(
                  for: attachment
                )
                Toggle(
                  isOn: Binding(
                    get: { selectedIDs.contains(attachment.id) },
                    set: { _ in onToggle(attachment.id) }
                  )
                ) {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.originalFilename)
                    if let knownFailureReason {
                      Text(knownFailureReason)
                        .font(.workbenchMetadata)
                        .foregroundStyle(.workbenchSecondary)
                    }
                  }
                }
                .toggleStyle(.checkbox)
                .disabled(!selectedIDs.contains(attachment.id) && knownFailureReason != nil)
              }
            }
          }
          .frame(maxHeight: 280)

          Divider()
          HStack {
            Button("清空图片选择", action: onClear)
              .disabled(selectedIDs.isEmpty)
            Spacer()
            Button("完成") { isPresented = false }
              .keyboardShortcut(.defaultAction)
          }
        }
      }
      .padding(WorkbenchSpacing.content)
      .frame(minWidth: 280)
    }
  }
}
