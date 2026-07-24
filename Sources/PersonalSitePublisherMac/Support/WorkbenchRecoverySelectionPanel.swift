import AppKit
import UniformTypeIdentifiers

enum WorkbenchRecoverySelectionPanel {
  @MainActor
  static func chooseSnapshot() -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择工作台恢复文件")
    panel.prompt = String(localized: "验证并恢复")
    panel.message = String(localized: "所选 JSON 必须是由本应用保存的有效工作台快照。成功后应用会退出，重新打开即可载入。")
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.json]
    return panel.runModal() == .OK ? panel.url : nil
  }

  @MainActor
  static func chooseExportDirectory() -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "导出工作台故障文件")
    panel.prompt = String(localized: "导出")
    panel.message = String(localized: "应用会创建独立恢复文件夹，并复制主文件和上次有效备份；原文件不会改变。")
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
  }
}
