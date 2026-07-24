import AppKit

enum KnowledgeBatchExportSelectionPanel {
  @MainActor
  static func chooseDestinationDirectory() -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择资料导出文件夹")
    panel.prompt = String(localized: "导出到此处")
    panel.message = String(localized: "每条资料会导出为一个带元数据的 Markdown 文件；资料库本身不会被修改。")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
  }
}
