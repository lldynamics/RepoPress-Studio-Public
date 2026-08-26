import Foundation
import XCTest

@testable import PublishingMarkdownCore

final class MarkdownDocumentExportNetworkSecurityTests: XCTestCase {
  func testPDFAndPrintPlansInstallFailClosedSubresourcePolicy() throws {
    let service = MarkdownDocumentExportPlanningService()
    let markdown = """
      # 正文

      [保留的外部链接](https://docs.example.test/read)

      ![loopback](http://127.0.0.1/private.png)

      <img src="http://192.168.1.10/private.png" alt="private">
      <img src="http://[::1]/loopback.png" alt="IPv6">
      <img src="HTTPS://rebind.example.test/image.png" alt="DNS">
      <img src="data:image/png;base64,AA==" alt="inline">
      <video src="http://localhost:8080/private.mp4"></video>
      """

    for format in [MarkdownDocumentExportFormat.pdf, .print] {
      let plan = try service.plan(
        title: "Network isolation",
        markdown: markdown,
        format: format
      )
      let html = try htmlPayload(from: plan)
      let policy = MarkdownDocumentExportPlanningService
        .networkIsolationContentSecurityPolicy

      XCTAssertTrue(
        html.contains(
          "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
        )
      )
      XCTAssertTrue(policy.contains("default-src 'none'"))
      XCTAssertTrue(policy.contains("script-src 'none'"))
      XCTAssertTrue(policy.contains("img-src data: file: publisher-asset:"))
      XCTAssertTrue(policy.contains("media-src data: file: publisher-asset:"))
      XCTAssertTrue(policy.contains("connect-src 'none'"))
      XCTAssertFalse(policy.lowercased().contains("http:"))
      XCTAssertFalse(policy.lowercased().contains("https:"))

      // Legitimate text, user-activated links and inline images remain in the
      // document. Network subresource URLs may remain as inert markup because
      // both this policy and the executor's content rule block their loading.
      XCTAssertTrue(html.contains("<h1>正文</h1>"))
      XCTAssertTrue(html.contains("href=\"https://docs.example.test/read\""))
      XCTAssertTrue(html.contains("data:image/png;base64,AA=="))
    }
  }

  func testHTMLFileExportPreservesLinksButCannotAutomaticallyLoadNetworkResources() throws {
    let plan = try MarkdownDocumentExportPlanningService().plan(
      title: "Portable HTML",
      markdown: """
        [文档](https://docs.example.test/read)
        ![远程图片](https://cdn.example.test/image.png)
        """,
      format: .html
    )
    let html = try htmlPayload(from: plan)
    let policy = MarkdownDocumentExportPlanningService.networkIsolationContentSecurityPolicy

    XCTAssertEqual(plan.operation, .writeUTF8File)
    XCTAssertTrue(html.contains("href=\"https://docs.example.test/read\""))
    XCTAssertTrue(html.contains("src=\"https://cdn.example.test/image.png\""))
    XCTAssertTrue(html.contains("content=\"\(policy)\""))
    XCTAssertFalse(policy.lowercased().contains("http:"))
    XCTAssertFalse(policy.lowercased().contains("https:"))
  }

  private func htmlPayload(from plan: MarkdownDocumentExportPlan) throws -> String {
    guard case .html(let html) = plan.payload else {
      XCTFail("Expected an HTML export payload")
      return ""
    }
    return html
  }
}
