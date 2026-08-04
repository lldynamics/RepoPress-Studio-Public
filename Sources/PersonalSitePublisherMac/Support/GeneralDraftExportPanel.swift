import AppKit
import PublishingWorkbenchCore
import UniformTypeIdentifiers

enum GeneralDraftExportPanel {
  @MainActor
  static func export(_ document: GeneralDraftExportDocument) throws -> URL? {
    let panel = NSSavePanel()
    panel.title = String(localized: "导出通用草稿")
    panel.prompt = String(localized: "导出")
    panel.message = String(localized: "导出为独立 Markdown 文件；软件中的通用草稿会继续保留。")
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    panel.nameFieldStringValue = document.suggestedFilename

    guard panel.runModal() == .OK, let destinationURL = panel.url else {
      return nil
    }
    try document.markdown.write(to: destinationURL, atomically: true, encoding: .utf8)
    return destinationURL
  }
}
