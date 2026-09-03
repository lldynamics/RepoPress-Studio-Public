import SwiftUI

struct MarkdownWritingContextPanelContainer<Content: View>: View {
  let selectedPanel: MarkdownWritingContextPanel
  let availablePanels: [MarkdownWritingContextPanel]
  let onSelectPanel: (MarkdownWritingContextPanel) -> Void
  let onClose: () -> Void
  let content: Content

  init(
    selectedPanel: MarkdownWritingContextPanel,
    availablePanels: [MarkdownWritingContextPanel],
    onSelectPanel: @escaping (MarkdownWritingContextPanel) -> Void,
    onClose: @escaping () -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.selectedPanel = selectedPanel
    self.availablePanels = availablePanels
    self.onSelectPanel = onSelectPanel
    self.onClose = onClose
    self.content = content()
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Menu {
          ForEach(availablePanels) { panel in
            Button {
              onSelectPanel(panel)
            } label: {
              if panel == selectedPanel {
                Label(panel.title, systemImage: "checkmark")
              } else {
                Label(panel.title, systemImage: panel.systemImage)
              }
            }
          }
        } label: {
          Label(selectedPanel.title, systemImage: selectedPanel.systemImage)
            .font(.headline)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .accessibilityLabel("写作上下文面板")
        .accessibilityValue(selectedPanel.title)

        Spacer(minLength: 8)

        Button(action: onClose) {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help(String(localized: "关闭上下文面板"))
        .accessibilityLabel("关闭上下文面板")
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
    .frame(minWidth: 280, idealWidth: 360, maxWidth: 420, maxHeight: .infinity)
    .background(WorkbenchBackgroundStyle.card)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("markdown-writing-context-panel")
  }
}
