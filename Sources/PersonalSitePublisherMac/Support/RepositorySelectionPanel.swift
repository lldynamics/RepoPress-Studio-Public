import AppKit
import Foundation
import UniformTypeIdentifiers

enum RepositorySelectionPanel {
  @MainActor
  static func chooseDirectory() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "选择本地站点仓库"
    panel.prompt = "选择"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
  }
}

enum ImageSelectionPanel {
  @MainActor
  static func chooseImages() -> [URL] {
    let panel = NSOpenPanel()
    panel.title = "选择要插入的图片"
    panel.prompt = "插入"
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, .tiff]
    return panel.runModal() == .OK ? panel.urls : []
  }
}
