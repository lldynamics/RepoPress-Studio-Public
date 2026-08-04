import AppKit
import Foundation
import PublishingWorkbenchCore
import UniformTypeIdentifiers
import WebKit

enum MarkdownDocumentExportExecutionResult: Equatable {
  case saved(URL)
  case printed
  case shared
  case cancelled

  var userMessage: String {
    switch self {
    case .saved(let url):
      "已导出：\(url.lastPathComponent)"
    case .printed:
      "文稿已发送到打印系统。"
    case .shared:
      "已打开系统分享菜单。"
    case .cancelled:
      "已取消导出。"
    }
  }
}

enum MarkdownDocumentExportExecutionError: LocalizedError {
  case invalidPayload
  case noPresentationView
  case printFailed

  var errorDescription: String? {
    switch self {
    case .invalidPayload:
      "导出计划中的内容格式不正确。"
    case .noPresentationView:
      "当前没有可用于显示分享菜单的窗口。"
    case .printFailed:
      "打印任务未能提交。"
    }
  }
}

@MainActor
enum MarkdownDocumentExportExecutor {
  static func execute(
    _ plan: MarkdownDocumentExportPlan
  ) async throws -> MarkdownDocumentExportExecutionResult {
    switch plan.operation {
    case .writeUTF8File:
      guard let destinationURL = chooseDestination(for: plan) else {
        return .cancelled
      }
      try fileData(for: plan).write(to: destinationURL, options: .atomic)
      return .saved(destinationURL)

    case .renderHTMLToPDF:
      guard let destinationURL = chooseDestination(for: plan) else {
        return .cancelled
      }
      let webView = try await renderedWebView(for: plan)
      let configuration = WKPDFConfiguration()
      configuration.rect = NSRect(x: 0, y: 0, width: 816, height: 1056)
      let data = try await pdfData(from: webView, configuration: configuration)
      try data.write(to: destinationURL, options: .atomic)
      return .saved(destinationURL)

    case .printHTML:
      let webView = try await renderedWebView(for: plan)
      let operation = NSPrintOperation(view: webView)
      operation.showsPrintPanel = true
      operation.showsProgressPanel = true
      return operation.run() ? .printed : .cancelled

    case .shareMarkdown:
      guard case .text(let markdown) = plan.payload else {
        throw MarkdownDocumentExportExecutionError.invalidPayload
      }
      guard let view = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else {
        throw MarkdownDocumentExportExecutionError.noPresentationView
      }
      MarkdownDocumentSharingPresenter.shared.present(
        items: [markdown as NSString],
        relativeTo: view
      )
      return .shared
    }
  }

  static func fileData(for plan: MarkdownDocumentExportPlan) throws -> Data {
    let value: String
    switch plan.payload {
    case .text(let text):
      value = text
    case .html(let html):
      value = html
    }
    guard let data = value.data(using: .utf8) else {
      throw MarkdownDocumentExportExecutionError.invalidPayload
    }
    return data
  }

  private static func chooseDestination(
    for plan: MarkdownDocumentExportPlan
  ) -> URL? {
    let panel = NSSavePanel()
    panel.title = exportPanelTitle(for: plan.format)
    panel.prompt = String(localized: "导出")
    panel.message = String(localized: "选择导出文件的保存位置。")
    panel.canCreateDirectories = true
    panel.isExtensionHidden = false
    if let suggestedFilename = plan.suggestedFilename {
      panel.nameFieldStringValue = suggestedFilename
    }
    if let fileExtension = plan.format.defaultFileExtension,
      let contentType = UTType(filenameExtension: fileExtension)
    {
      panel.allowedContentTypes = [contentType]
    }
    return panel.runModal() == .OK ? panel.url : nil
  }

  private static func exportPanelTitle(
    for format: MarkdownDocumentExportFormat
  ) -> String {
    switch format {
    case .markdown:
      String(localized: "导出 Markdown")
    case .html:
      String(localized: "导出 HTML")
    case .pdf:
      String(localized: "导出 PDF")
    case .print:
      String(localized: "打印文章")
    case .share:
      String(localized: "分享文章")
    }
  }

  private static func renderedWebView(
    for plan: MarkdownDocumentExportPlan
  ) async throws -> WKWebView {
    guard case .html(let html) = plan.payload else {
      throw MarkdownDocumentExportExecutionError.invalidPayload
    }
    let webView = WKWebView(
      frame: NSRect(x: 0, y: 0, width: 816, height: 1056)
    )
    let loader = MarkdownExportHTMLLoader()
    try await loader.load(html: html, in: webView)
    webView.layoutSubtreeIfNeeded()
    return webView
  }

  private static func pdfData(
    from webView: WKWebView,
    configuration: WKPDFConfiguration
  ) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      webView.createPDF(configuration: configuration) { result in
        continuation.resume(with: result)
      }
    }
  }
}

@MainActor
private final class MarkdownExportHTMLLoader: NSObject, WKNavigationDelegate {
  private var continuation: CheckedContinuation<Void, Error>?

  func load(html: String, in webView: WKWebView) async throws {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      webView.navigationDelegate = self
      webView.loadHTMLString(html, baseURL: nil)
    }
    webView.navigationDelegate = nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
    finish(with: .success(()))
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation?,
    withError error: Error
  ) {
    finish(with: .failure(error))
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation?,
    withError error: Error
  ) {
    finish(with: .failure(error))
  }

  private func finish(with result: Result<Void, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume(with: result)
  }
}

@MainActor
private final class MarkdownDocumentSharingPresenter {
  static let shared = MarkdownDocumentSharingPresenter()

  private var activePicker: NSSharingServicePicker?

  func present(items: [Any], relativeTo view: NSView) {
    let picker = NSSharingServicePicker(items: items)
    activePicker = picker
    let anchor = NSRect(
      x: view.bounds.midX,
      y: view.bounds.maxY,
      width: 1,
      height: 1
    )
    picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
  }
}
