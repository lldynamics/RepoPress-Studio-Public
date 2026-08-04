import AppKit
import Foundation
import PublishingWorkbenchCore
import UniformTypeIdentifiers

enum RepositorySelectionPanel {
  @MainActor
  static func chooseDirectory() -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择本地站点仓库")
    panel.prompt = String(localized: "选择")
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
    panel.title = String(localized: "选择要插入的图片")
    panel.prompt = String(localized: "插入")
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, .tiff]
    return panel.runModal() == .OK ? panel.urls : []
  }
}

enum VideoSelectionPanel {
  @MainActor
  static func chooseVideos() -> [URL] {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择要插入的视频")
    panel.prompt = String(localized: "插入视频")
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = VideoFileSupport.supportedExtensions.compactMap {
      UTType(filenameExtension: $0)
    }
    guard panel.runModal() == .OK else { return [] }
    return VideoFileSupport.supportedVideoURLs(in: panel.urls)
  }
}

enum ContentMigrationSelectionPanel {
  @MainActor
  static func chooseSource() -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择博客导出包或 Markdown 文件夹")
    panel.prompt = String(localized: "生成迁移预览")
    panel.message = String(localized: "支持 WordPress WXR、RSS/Atom、JSON 导出、单篇 Markdown 或 Markdown 文件夹。")
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.xml, .json, .plainText, .folder]
    return panel.runModal() == .OK ? panel.url : nil
  }

  @MainActor
  static func chooseRedirectTableDestination() -> URL? {
    let panel = NSSavePanel()
    panel.title = String(localized: "导出重定向表")
    panel.prompt = String(localized: "导出 CSV")
    panel.nameFieldStringValue = "redirects.csv"
    panel.allowedContentTypes = [.commaSeparatedText]
    return panel.runModal() == .OK ? panel.url : nil
  }
}
