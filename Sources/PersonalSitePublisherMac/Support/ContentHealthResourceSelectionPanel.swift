import AppKit
import Foundation

enum ContentHealthResourceSelectionPanel {
  @MainActor
  static func chooseResource(repositoryRootURL: URL) -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择正确的站内资源")
    panel.prompt = String(localized: "修复路径")
    panel.message = String(localized: "请选择当前站点仓库内的文件；仓库外文件不会被写入文章。")
    panel.directoryURL = repositoryRootURL
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
  }
}
