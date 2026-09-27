import SwiftUI

struct MarkdownWritingContextPanelContainer<Content: View>: View {
  let selectedPanel: MarkdownWritingContextPanel
  let onClose: () -> Void
  let content: Content

  init(
    selectedPanel: MarkdownWritingContextPanel,
    onClose: @escaping () -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.selectedPanel = selectedPanel
    self.onClose = onClose
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Label(selectedPanel.title, systemImage: selectedPanel.systemImage)
          .font(.headline)

        Spacer(minLength: 8)

        Button(action: onClose) {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help(String(localized: "关闭"))
        .accessibilityLabel("关闭")
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)

      Divider()

      ScrollView {
        content
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
      }
    }
    .frame(minWidth: 360, idealWidth: 460, maxWidth: 520, maxHeight: .infinity)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55))
    }
    .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("markdown-writing-context-panel")
  }
}
