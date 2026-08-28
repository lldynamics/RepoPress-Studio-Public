import AppKit
import UniformTypeIdentifiers

enum KnowledgeSelectionPanel {
  @MainActor
  static func chooseSource() -> URL? {
    chooseSources().first
  }

  @MainActor
  static func chooseSources() -> [URL] {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择要加入资料库的文件或文件夹")
    panel.prompt = String(localized: "生成导入预览")
    panel.message = String(
      localized: "支持 JPEG、PNG、HEIC 图片、EPUB、Markdown、文本、HTML、PDF 和包含这些文件的文件夹。"
    )
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [
      .jpeg,
      .png,
      .heic,
      .epub,
      .pdf,
      .plainText,
      .html,
      .folder,
    ]
    return panel.runModal() == .OK ? panel.urls : []
  }
}
