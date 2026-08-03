import AppKit

enum WorkbenchDiagnosticsSelectionPanel {
  @MainActor
  static func chooseExportDirectory() -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择诊断包导出位置")
    panel.prompt = String(localized: "导出")
    panel.message = String(localized: "只会创建用户主动选择的脱敏 ZIP；不包含草稿正文、附件、API Key 或钥匙串内容。")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
  }
}
