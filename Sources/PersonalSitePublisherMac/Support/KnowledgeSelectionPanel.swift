import AppKit
import UniformTypeIdentifiers

enum KnowledgeSelectionPanel {
  @MainActor
  static func chooseSource() -> URL? {
    let panel = NSOpenPanel()
    panel.title = String(localized: "选择要加入资料库的文件或文件夹")
    panel.prompt = String(localized: "生成导入预览")
    panel.message = String(localized: "支持 EPUB、Markdown、文本、HTML、PDF 和包含这些文件的文件夹。")
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.epub, .pdf, .plainText, .html, .folder]
    return panel.runModal() == .OK ? panel.url : nil
  }
}
