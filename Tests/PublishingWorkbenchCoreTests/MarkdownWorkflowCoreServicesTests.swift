import Foundation
import PublishingMarkdownCore
import XCTest

final class MarkdownWorkflowCoreServicesTests: XCTestCase {
  func testExportPlansAllFormatsWithoutInvokingPlatformUI() throws {
    let service = MarkdownDocumentExportPlanningService()
    let markdown = "# 正文\n\n内容"

    let markdownPlan = try service.plan(
      title: "发布说明",
      markdown: markdown,
      format: .markdown
    )
    XCTAssertEqual(markdownPlan.operation, .writeUTF8File)
    XCTAssertEqual(markdownPlan.suggestedFilename, "发布说明.md")
    XCTAssertEqual(markdownPlan.payload, .text(markdown))

    let htmlPlan = try service.plan(
      title: "<发布>",
      markdown: markdown,
      format: .html
    )
    XCTAssertEqual(htmlPlan.operation, .writeUTF8File)
    guard case .html(let html) = htmlPlan.payload else {
      return XCTFail("HTML 导出应返回 HTML 载荷")
    }
    XCTAssertTrue(html.contains("<title>&lt;发布&gt;</title>"))
    XCTAssertTrue(html.contains("<h1>正文</h1>"))

    XCTAssertEqual(
      try service.plan(title: "PDF", markdown: markdown, format: .pdf).operation,
      .renderHTMLToPDF
    )
    XCTAssertEqual(
      try service.plan(title: "打印", markdown: markdown, format: .print).operation,
      .printHTML
    )
    XCTAssertNil(
      try service.plan(title: "打印", markdown: markdown, format: .print).suggestedFilename
    )
    XCTAssertEqual(
      try service.plan(title: "分享", markdown: markdown, format: .share).operation,
      .shareMarkdown
    )
  }

  func testExportSafeFilenameAndAvailabilityValidation() throws {
    let service = MarkdownDocumentExportPlanningService()
    XCTAssertEqual(
      service.safeFilename(" ../项目:发布/CON?.md ", fileExtension: "md"),
      "项目-发布-CON.md"
    )
    XCTAssertEqual(
      service.safeFilename("CON", fileExtension: "pdf"),
      "CON-document.pdf"
    )
    XCTAssertEqual(
      service.safeFilename("报告", fileExtension: "p/d*f"),
      "报告.pdf"
    )

    let unavailable = service.availability(
      title: "文章",
      markdown: "正文",
      format: .pdf,
      capabilities: MarkdownDocumentExportCapabilities(
        canWriteFiles: false,
        canRenderPDF: false
      )
    )
    XCTAssertEqual(
      unavailable.issues,
      [.fileWritingUnavailable, .pdfRenderingUnavailable]
    )
    XCTAssertThrowsError(
      try service.plan(
        title: "",
        markdown: " \n ",
        format: .share
      )
    ) { error in
      XCTAssertEqual(
        error as? MarkdownDocumentExportPlanningError,
        .unavailable([.emptyDocument])
      )
    }
  }
}
