import Foundation
import PublishingWorkbenchCore
import XCTest

final class LocalProcessingAndPreviewTests: XCTestCase {
  func testLocalWhisperUsesLocalProcessAndReturnsTranscript() async throws {
    let audioURL = temporaryURL(extension: "wav")
    let modelURL = temporaryURL(extension: "bin")
    defer {
      try? FileManager.default.removeItem(at: audioURL)
      try? FileManager.default.removeItem(at: modelURL)
    }
    try Data(repeating: 0, count: 16).write(to: audioURL)
    try Data(repeating: 0, count: 16).write(to: modelURL)
    let runner = FakeWhisperRunner()
    let result = try await LocalWhisperTranscriptionService(processRunner: runner).transcribe(
      audioURL: audioURL,
      configuration: LocalWhisperConfiguration(
        executablePath: "/usr/bin/true",
        modelPath: modelURL.path,
        language: "zh"
      )
    )
    XCTAssertEqual(result.text, "第一句\n第二句")
    XCTAssertEqual(result.language, "zh")
    let arguments = await runner.arguments()
    XCTAssertTrue(arguments.contains("-nt"))
    XCTAssertTrue(arguments.contains("-otxt"))
  }

  func testLocalKaTeXPreviewRendersCommonFormulaAndKeepsCodeLiteral() {
    let html = MarkdownHTMLRenderingService.renderPreviewBodyAllowingSanitizedHTML(
      #"""
      公式 $\frac{a}{b}+\alpha^2$。

      ```
      $\frac{not}{rendered}$
      ```
      """#
    )
    XCTAssertTrue(html.contains("local-katex-inline"))
    XCTAssertTrue(html.contains("math-fraction"))
    XCTAssertTrue(html.contains("α"))
    XCTAssertTrue(html.contains("\\frac{not}"))
    XCTAssertFalse(html.contains("<script"))
  }

  private func temporaryURL(extension: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("repopress-media-test-\(UUID().uuidString)")
      .appendingPathExtension(`extension`)
  }
}

private actor FakeWhisperRunner: LocalWhisperProcessRunner {
  private var capturedArguments: [String] = []

  func run(executableURL: URL, arguments: [String]) async throws -> LocalWhisperProcessResult {
    capturedArguments = arguments
    guard let outputIndex = arguments.firstIndex(of: "-of"),
          arguments.indices.contains(outputIndex + 1) else {
      return LocalWhisperProcessResult(exitCode: 1, standardOutput: "", standardError: "missing output")
    }
    let outputURL = URL(fileURLWithPath: arguments[outputIndex + 1] + ".txt")
    try "第一句\n第二句\n".write(to: outputURL, atomically: true, encoding: .utf8)
    return LocalWhisperProcessResult(exitCode: 0, standardOutput: "", standardError: "")
  }

  func arguments() -> [String] {
    capturedArguments
  }
}
