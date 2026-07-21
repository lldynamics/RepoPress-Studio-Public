import Darwin
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class HTMLSourceEditingServiceTests: XCTestCase {
  private let service = HTMLSourceEditingService()

  func testOpenAndSavePreservesUTF8BOMAndCRLF() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let fileURL = fixture.root.appendingPathComponent("templates/page.html")
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let originalBody = "<main>第一行</main>\r\n<p>第二行</p>\r\n"
    var originalData = Data([0xEF, 0xBB, 0xBF])
    originalData.append(try XCTUnwrap(originalBody.data(using: .utf8)))
    try originalData.write(to: fileURL)

    var document = try service.open(
      profile: fixture.profile,
      repositoryPath: "templates/page.html"
    )
    XCTAssertEqual(document.encoding, .utf8WithBOM)
    XCTAssertEqual(document.lineEnding, .crlf)
    XCTAssertEqual(document.text, "<main>第一行</main>\n<p>第二行</p>\n")

    document.text += "<footer>完成</footer>\n"
    let saved = try service.save(document, profile: fixture.profile)
    let stored = try Data(contentsOf: fileURL)
    XCTAssertTrue(stored.starts(with: [0xEF, 0xBB, 0xBF]))
    let storedText = try XCTUnwrap(String(data: stored.dropFirst(3), encoding: .utf8))
    XCTAssertTrue(storedText.contains("\r\n<footer>完成</footer>\r\n"))
    XCTAssertFalse(saved.hasUnsavedChanges)
  }

  func testExternalModificationRejectsSaveWithoutOverwritingDisk() throws {
    let fixture = try makeFixture(file: "index.html", contents: "<p>初始</p>\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var document = try service.open(profile: fixture.profile, repositoryPath: "index.html")
    document.text = "<p>编辑器更改</p>\n"
    let fileURL = fixture.root.appendingPathComponent("index.html")
    try Data("<p>外部更改</p>\n".utf8).write(to: fileURL)

    XCTAssertThrowsError(try service.save(document, profile: fixture.profile)) { error in
      XCTAssertEqual(error as? HTMLSourceEditingError, .externalModification)
    }
    XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "<p>外部更改</p>\n")
  }

  func testRejectsNonHTMLTraversalAndSymlink() throws {
    let fixture = try makeFixture(file: "index.html", contents: "<p>安全</p>")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    XCTAssertThrowsError(try service.open(profile: fixture.profile, repositoryPath: "../index.html")) {
      XCTAssertEqual($0 as? HTMLSourceEditingError, .unsafeRepositoryPath)
    }
    XCTAssertThrowsError(try service.open(profile: fixture.profile, repositoryPath: "README.md")) {
      XCTAssertEqual($0 as? HTMLSourceEditingError, .unsupportedFileType)
    }

    let outside = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".html")
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data("outside".utf8).write(to: outside)
    let link = fixture.root.appendingPathComponent("linked.html")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    XCTAssertThrowsError(try service.open(profile: fixture.profile, repositoryPath: "linked.html")) {
      XCTAssertEqual($0 as? HTMLSourceEditingError, .symbolicLinkNotAllowed)
    }
  }

  func testRejectsIntermediateDirectorySymlink() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let outsideDirectory = fixture.root.deletingLastPathComponent()
      .appendingPathComponent("html-source-outside-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: outsideDirectory) }
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    try Data("<p>outside</p>".utf8)
      .write(to: outsideDirectory.appendingPathComponent("page.html"))
    try FileManager.default.createSymbolicLink(
      at: fixture.root.appendingPathComponent("linked-directory"),
      withDestinationURL: outsideDirectory
    )

    XCTAssertThrowsError(
      try service.open(
        profile: fixture.profile,
        repositoryPath: "linked-directory/page.html"
      )
    ) {
      XCTAssertEqual($0 as? HTMLSourceEditingError, .symbolicLinkNotAllowed)
    }
  }

  func testPreservesUTF16ByteOrderAndCRLineEndings() throws {
    for (name, encoding, bom) in [
      ("little.html", String.Encoding.utf16LittleEndian, Data([0xFF, 0xFE])),
      ("big.html", String.Encoding.utf16BigEndian, Data([0xFE, 0xFF]))
    ] {
      let fixture = try makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let fileURL = fixture.root.appendingPathComponent(name)
      var data = bom
      data.append(try XCTUnwrap("<p>第一行</p>\r<p>第二行</p>\r".data(using: encoding)))
      try data.write(to: fileURL)

      var document = try service.open(profile: fixture.profile, repositoryPath: name)
      XCTAssertEqual(document.lineEnding, .cr)
      document.text += "<footer>完成</footer>\n"
      _ = try service.save(document, profile: fixture.profile)

      let stored = try Data(contentsOf: fileURL)
      XCTAssertTrue(stored.starts(with: bom))
      let decoded = try XCTUnwrap(String(data: stored.dropFirst(2), encoding: encoding))
      XCTAssertTrue(decoded.hasSuffix("\r<footer>完成</footer>\r"))
      XCTAssertFalse(decoded.contains("\n"))
    }
  }

  func testRejectsUTF32BeforeUTF16BOMDetection() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let fileURL = fixture.root.appendingPathComponent("utf32.html")
    try Data([0xFF, 0xFE, 0x00, 0x00, 0x3C, 0x00, 0x00, 0x00]).write(to: fileURL)

    XCTAssertThrowsError(
      try service.open(profile: fixture.profile, repositoryPath: "utf32.html")
    ) {
      XCTAssertEqual($0 as? HTMLSourceEditingError, .unsupportedEncoding)
    }
  }

  func testRejectsOversizedFileAndListsHTMLCaseInsensitively() throws {
    let fixture = try makeFixture(file: "Page.HTM", contents: "<p>页面</p>")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let largeURL = fixture.root.appendingPathComponent("large.html")
    try Data(repeating: 65, count: HTMLSourceEditingService.maximumEditableByteCount + 1)
      .write(to: largeURL)

    let descriptors = try service.listDocuments(profile: fixture.profile)
    XCTAssertEqual(descriptors.map(\.repositoryPath), ["large.html", "Page.HTM"])
    XCTAssertEqual(descriptors.first?.isEditable, false)
    XCTAssertThrowsError(try service.open(profile: fixture.profile, repositoryPath: "large.html")) {
      guard case .fileTooLarge = $0 as? HTMLSourceEditingError else {
        return XCTFail("Expected fileTooLarge, got \($0)")
      }
    }
  }

  func testMixedLineEndingsAreDetectedAndRejectedWithoutRewritingDisk() throws {
    let original = "<p>CRLF</p>\r\n<p>LF</p>\n"
    let fixture = try makeFixture(file: "mixed.html", contents: original)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var document = try service.open(profile: fixture.profile, repositoryPath: "mixed.html")

    XCTAssertTrue(document.hasMixedLineEndings)
    document.text += "<footer>不应写入</footer>\n"
    XCTAssertThrowsError(try service.save(document, profile: fixture.profile)) {
      XCTAssertEqual($0 as? HTMLSourceEditingError, .mixedLineEndings)
    }
    XCTAssertEqual(
      try String(contentsOf: fixture.root.appendingPathComponent("mixed.html"), encoding: .utf8),
      original
    )
  }

  func testSavePreservesPOSIXModeDespiteProcessUmask() throws {
    let fixture = try makeFixture(file: "mode.html", contents: "<p>初始</p>\n")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let fileURL = fixture.root.appendingPathComponent("mode.html")
    XCTAssertEqual(Darwin.chmod(fileURL.path, mode_t(0o664)), 0)

    var document = try service.open(profile: fixture.profile, repositoryPath: "mode.html")
    document.text = "<p>已保存</p>\n"
    _ = try service.save(document, profile: fixture.profile)

    var fileStat = stat()
    XCTAssertEqual(Darwin.lstat(fileURL.path, &fileStat), 0)
    XCTAssertEqual(fileStat.st_mode & mode_t(0o7777), mode_t(0o664))
  }

  func testResolvedFileOperationUsesStableSnapshotInsteadOfRepositoryPath() throws {
    let fixture = try makeFixture(file: "preview.html", contents: "<p>已验证</p>")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let fileURL = fixture.root.appendingPathComponent("preview.html")
    let outsideURL = fixture.root.deletingLastPathComponent()
      .appendingPathComponent("preview-outside-\(UUID().uuidString).html")
    defer { try? FileManager.default.removeItem(at: outsideURL) }
    try Data("<p>外部</p>".utf8).write(to: outsideURL)

    var snapshotURL: URL?
    let previewText = try service.withResolvedFileURL(
      profile: fixture.profile,
      repositoryPath: "preview.html"
    ) { url in
      snapshotURL = url
      XCTAssertNotEqual(url.standardizedFileURL, fileURL.standardizedFileURL)
      try FileManager.default.removeItem(at: fileURL)
      try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: outsideURL)
      return try String(contentsOf: url, encoding: .utf8)
    }

    XCTAssertEqual(previewText, "<p>已验证</p>")
    if let snapshotURL {
      try? FileManager.default.removeItem(at: snapshotURL.deletingLastPathComponent())
    }
  }

  func testResolvedPreviewCopiesRelativeAssetsAndNestedCSSDependencies() throws {
    let fixture = try makeFixture(
      file: "pages/preview.html",
      contents: """
      <!doctype html>
      <link rel="stylesheet" href="../assets/site.css">
      <img srcset="../assets/hero.png 1x, ../assets/hero@2x.png 2x">
      <div style="background-image: url('../assets/inline.png')"></div>
      <script src="https://example.com/remote.js"></script>
      """
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let assetsURL = fixture.root.appendingPathComponent("assets", isDirectory: true)
    try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
    try Data("body { background: url('images/background.png'); }".utf8)
      .write(to: assetsURL.appendingPathComponent("site.css"))
    try FileManager.default.createDirectory(
      at: assetsURL.appendingPathComponent("images", isDirectory: true),
      withIntermediateDirectories: true
    )
    for path in ["hero.png", "hero@2x.png", "inline.png", "images/background.png"] {
      try Data([0x89, 0x50, 0x4E, 0x47]).write(to: assetsURL.appendingPathComponent(path))
    }

    var previewRootURL: URL?
    try service.withResolvedFileURL(
      profile: fixture.profile,
      repositoryPath: "pages/preview.html"
    ) { snapshotURL in
      let rootURL = snapshotURL.deletingLastPathComponent().deletingLastPathComponent()
      previewRootURL = rootURL
      for path in [
        "assets/site.css",
        "assets/hero.png",
        "assets/hero@2x.png",
        "assets/inline.png",
        "assets/images/background.png"
      ] {
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(path).path))
      }
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("remote.js").path)
      )
    }
    if let previewRootURL {
      try? FileManager.default.removeItem(at: previewRootURL)
    }
  }

  func testResolvedPreviewRemovesExpiredTemporaryPackages() throws {
    let fixture = try makeFixture(file: "preview.html", contents: "<p>preview</p>")
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let expiredURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PersonalSitePublisher-HTMLPreview-expired-test-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: expiredURL, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -48 * 60 * 60)],
      ofItemAtPath: expiredURL.path
    )

    var previewRootURL: URL?
    try service.withResolvedFileURL(
      profile: fixture.profile,
      repositoryPath: "preview.html"
    ) { snapshotURL in
      previewRootURL = snapshotURL.deletingLastPathComponent()
    }

    XCTAssertFalse(FileManager.default.fileExists(atPath: expiredURL.path))
    if let previewRootURL {
      try? FileManager.default.removeItem(at: previewRootURL)
    }
  }

  func testRepositoryReplacementAtSamePathIsRejected() throws {
    let fixture = try makeFixture(file: "index.html", contents: "<p>初始</p>\n")
    let displacedRoot = fixture.root.deletingLastPathComponent()
      .appendingPathComponent("displaced-repository-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: fixture.root)
      try? FileManager.default.removeItem(at: displacedRoot)
    }
    var document = try service.open(profile: fixture.profile, repositoryPath: "index.html")
    document.text = "<p>编辑器更改</p>\n"

    try FileManager.default.moveItem(at: fixture.root, to: displacedRoot)
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    try Data("<p>初始</p>\n".utf8)
      .write(to: fixture.root.appendingPathComponent("index.html"))

    XCTAssertThrowsError(try service.save(document, profile: fixture.profile)) {
      XCTAssertEqual($0 as? HTMLSourceEditingError, .repositoryChanged)
    }
    XCTAssertEqual(
      try String(
        contentsOf: fixture.root.appendingPathComponent("index.html"),
        encoding: .utf8
      ),
      "<p>初始</p>\n"
    )
  }

  func testFIFOWithHTMLExtensionIsRejectedWithoutBlocking() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let fifoURL = fixture.root.appendingPathComponent("pipe.html")
    XCTAssertEqual(Darwin.mkfifo(fifoURL.path, mode_t(0o600)), 0)

    let startedAt = Date()
    XCTAssertThrowsError(
      try service.open(profile: fixture.profile, repositoryPath: "pipe.html")
    ) {
      XCTAssertEqual($0 as? HTMLSourceEditingError, .fileNotFound)
    }
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
  }

  func testDetectsTemplateDialectFromSiteKind() {
    XCTAssertEqual(
      HTMLSourceEditingService.detectDialect(text: "{% if page %}{{ page }}{% endif %}", siteKind: .zola),
      .tera
    )
    XCTAssertEqual(
      HTMLSourceEditingService.detectDialect(text: "{{ .Site.Title }}", siteKind: .hugo),
      .goTemplate
    )
    XCTAssertEqual(
      HTMLSourceEditingService.detectDialect(text: "{{ page.title }}", siteKind: .jekyll),
      .liquid
    )
    XCTAssertEqual(
      HTMLSourceEditingService.detectDialect(text: "<!doctype html>", siteKind: .hexo),
      .html
    )
  }

  private func makeFixture(
    file: String? = nil,
    contents: String = ""
  ) throws -> (root: URL, profile: SiteProfile) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("html-source-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if let file {
      let url = root.appendingPathComponent(file)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data(contents.utf8).write(to: url)
    }
    let profile = SiteProfile(name: "测试站点", localRepositoryRootPath: root.path)
    return (root, profile)
  }
}
