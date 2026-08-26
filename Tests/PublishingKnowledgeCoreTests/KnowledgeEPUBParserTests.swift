import Foundation
import XCTest
@testable import PublishingKnowledgeCore

final class KnowledgeEPUBParserTests: XCTestCase {
  func testParsesMinimalEPUBAndNormalizesChapterPath() throws {
    let rootURL = try temporaryDirectory(named: "minimal")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = try makeEPUB(
      in: rootURL,
      packageXML: """
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>Minimal Book</dc:title>
          <dc:creator>Test Author</dc:creator>
          <dc:language>zh-Hans</dc:language>
          <dc:description>Short summary.</dc:description>
          <dc:subject>testing</dc:subject>
        </metadata>
        <manifest>
          <item id="chapter" href="Text/../Text/chapter.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine><itemref idref="chapter"/></spine>
      </package>
      """,
      chapters: [
        "OEBPS/Text/chapter.xhtml": """
        <!doctype html><html><head><title>Chapter One</title></head><body>
        <h1>Chapter One</h1><p>Durable notes stay searchable.</p>
        </body></html>
        """
      ]
    )

    let book = try KnowledgeEPUBParser().parse(
      data: Data(contentsOf: sourceURL),
      sourceName: "minimal.epub"
    )

    XCTAssertEqual(book.title, "Minimal Book")
    XCTAssertEqual(book.authors, ["Test Author"])
    XCTAssertEqual(book.language, "zh-Hans")
    XCTAssertEqual(book.summary, "Short summary.")
    XCTAssertEqual(book.tags, ["testing"])
    XCTAssertEqual(book.sections.count, 1)
    XCTAssertEqual(book.sections.first?.headingPath, "Chapter One")
    XCTAssertTrue(book.sections.first?.text.contains("Durable notes stay searchable.") ?? false)
    XCTAssertTrue(book.warnings.contains { $0.contains("阅读顺序") })
  }

  func testRejectsDTDDeclarationBeforeXMLParsing() throws {
    let rootURL = try temporaryDirectory(named: "dtd")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = try makeEPUB(
      in: rootURL,
      packageXML: """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE package [<!ENTITY blocked "must not expand">]>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>&blocked;</dc:title></metadata>
        <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="chapter"/></spine>
      </package>
      """,
      chapters: [
        "OEBPS/chapter.xhtml": "<html><body><h1>Chapter</h1><p>Body</p></body></html>"
      ]
    )

    XCTAssertThrowsError(
      try KnowledgeEPUBParser().parse(
        data: Data(contentsOf: sourceURL),
        sourceName: "dtd.epub"
      )
    ) { error in
      guard case let KnowledgeLibraryError.unreadableSource(message) = error else {
        return XCTFail("Expected unreadableSource, got \(error)")
      }
      XCTAssertTrue(message.contains("DTD") || message.contains("实体"))
    }
  }

  func testRejectsChapterPathOutsideArchiveRoot() throws {
    let rootURL = try temporaryDirectory(named: "path-escape")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = try makeEPUB(
      in: rootURL,
      packageXML: """
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Unsafe Book</dc:title></metadata>
        <manifest><item id="escape" href="../../../outside.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="escape"/></spine>
      </package>
      """,
      chapters: [:]
    )

    XCTAssertThrowsError(
      try KnowledgeEPUBParser().parse(
        data: Data(contentsOf: sourceURL),
        sourceName: "path-escape.epub"
      )
    ) { error in
      guard case let KnowledgeLibraryError.unreadableSource(message) = error else {
        return XCTFail("Expected unreadableSource, got \(error)")
      }
      XCTAssertTrue(message.contains("路径越界"))
    }
  }

  private func temporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("PublishingKnowledgeCoreTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeEPUB(
    in rootURL: URL,
    packageXML: String,
    chapters: [String: String]
  ) throws -> URL {
    let fixtureURL = rootURL.appendingPathComponent("fixture", isDirectory: true)
    let metaURL = fixtureURL.appendingPathComponent("META-INF", isDirectory: true)
    let packageURL = fixtureURL.appendingPathComponent("OEBPS", isDirectory: true)
    try FileManager.default.createDirectory(at: metaURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try "application/epub+zip".write(
      to: fixtureURL.appendingPathComponent("mimetype"),
      atomically: true,
      encoding: .utf8
    )
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """.write(
      to: metaURL.appendingPathComponent("container.xml"),
      atomically: true,
      encoding: .utf8
    )
    try packageXML.write(
      to: packageURL.appendingPathComponent("content.opf"),
      atomically: true,
      encoding: .utf8
    )
    for (path, content) in chapters {
      let fileURL = fixtureURL.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    let archiveURL = rootURL.appendingPathComponent("book.epub")
    try runZIP(arguments: ["-q", "-X", "-0", archiveURL.path, "mimetype"], in: fixtureURL)
    try runZIP(arguments: ["-q", "-X", "-9", "-r", archiveURL.path, "META-INF", "OEBPS"], in: fixtureURL)
    return archiveURL
  }

  private func runZIP(arguments: [String], in directoryURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.arguments = arguments
    process.currentDirectoryURL = directoryURL
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let data = output.fileHandleForReading.readDataToEndOfFile()
      throw NSError(
        domain: "KnowledgeEPUBParserTests.zip",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]
      )
    }
  }
}
