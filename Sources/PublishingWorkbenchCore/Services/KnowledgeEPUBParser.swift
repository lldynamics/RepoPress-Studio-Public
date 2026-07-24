import AppKit
import Foundation
import zlib

struct KnowledgeEPUBBook: Sendable {
  var title: String
  var authors: [String]
  var language: String?
  var summary: String
  var tags: [String]
  var sections: [KnowledgeExtractedSection]
  var warnings: [String]
}

struct KnowledgeEPUBParser: Sendable {
  private let maximumArchiveEntries = 10_000
  private let maximumExpandedBytes = 200 * 1_024 * 1_024
  private let maximumEntryBytes = 32 * 1_024 * 1_024
  private let maximumChapterCount = 2_000
  private let maximumExtractedCharacters = 20_000_000

  func parse(data: Data, sourceName: String) throws -> KnowledgeEPUBBook {
    let archive = try EPUBZIPArchive(
      data: data,
      sourceName: sourceName,
      maximumEntryCount: maximumArchiveEntries,
      maximumExpandedBytes: maximumExpandedBytes,
      maximumEntryBytes: maximumEntryBytes
    )

    let mimetype = try archive.textEntry(named: "mimetype", maximumBytes: 256)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard mimetype == "application/epub+zip" else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（缺少有效的 EPUB mimetype）")
    }

    let containerData = try archive.entryData(named: "META-INF/container.xml")
    let packagePath = try packageDocumentPath(from: containerData, sourceName: sourceName)
    let packageData = try archive.entryData(named: packagePath)
    let package = try packageDocument(from: packageData, sourceName: sourceName)
    let packageDirectory = packagePath.split(separator: "/").dropLast().map(String.init)

    var sections: [KnowledgeExtractedSection] = []
    var warnings: [String] = []
    var skippedNonLinearCount = 0
    var skippedUnsupportedCount = 0
    var skippedEmptyCount = 0
    var extractedCharacterCount = 0

    guard !package.spine.isEmpty else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（书籍没有可读取的章节顺序）")
    }
    guard package.spine.count <= maximumChapterCount else {
      throw KnowledgeLibraryError.sourceLimitExceeded(
        "EPUB 章节超过 \(maximumChapterCount) 个：\(sourceName)"
      )
    }

    for spineItem in package.spine {
      try Task.checkCancellation()
      guard spineItem.isLinear else {
        skippedNonLinearCount += 1
        continue
      }
      guard let manifestItem = package.manifest[spineItem.idref] else {
        skippedUnsupportedCount += 1
        continue
      }
      guard manifestItem.mediaType == "application/xhtml+xml"
              || manifestItem.mediaType == "text/html" else {
        skippedUnsupportedCount += 1
        continue
      }
      guard !manifestItem.properties.contains("nav") else {
        continue
      }

      let chapterPath = try resolvedArchivePath(
        href: manifestItem.href,
        relativeTo: packageDirectory,
        sourceName: sourceName
      )
      let chapterData = try archive.entryData(named: chapterPath)
      let chapter = chapterText(from: chapterData)
      guard !chapter.text.isEmpty else {
        skippedEmptyCount += 1
        continue
      }

      extractedCharacterCount += chapter.text.count
      guard extractedCharacterCount <= maximumExtractedCharacters else {
        throw KnowledgeLibraryError.sourceLimitExceeded(
          "EPUB 可检索正文超过 \(maximumExtractedCharacters) 个字符：\(sourceName)"
        )
      }

      let ordinal = sections.count + 1
      let locator = chapter.title.map { "第 \(ordinal) 章 · \($0)" } ?? "第 \(ordinal) 章"
      sections.append(KnowledgeExtractedSection(
        headingPath: chapter.title,
        locator: locator,
        text: chapter.text
      ))
    }

    guard !sections.isEmpty else {
      throw KnowledgeLibraryError.emptyContent(sourceName)
    }
    if skippedNonLinearCount > 0 {
      warnings.append("已跳过 \(skippedNonLinearCount) 个标记为非线性阅读的 EPUB 附加页面。")
    }
    if skippedUnsupportedCount > 0 {
      warnings.append("有 \(skippedUnsupportedCount) 个 EPUB 章节引用缺失或不是 HTML 正文，未加入检索。")
    }
    if skippedEmptyCount > 0 {
      warnings.append("有 \(skippedEmptyCount) 个 EPUB 章节没有提取到正文。")
    }
    warnings.append("已按 EPUB 阅读顺序提取 \(sections.count) 个章节；图片、样式和脚本不会进入检索。")

    return KnowledgeEPUBBook(
      title: package.title?.nilIfEmpty ?? "",
      authors: package.authors.uniqueNonEmptyValues,
      language: package.language?.nilIfEmpty,
      summary: package.summary.map(inlineHTMLText)?.nilIfEmpty ?? "",
      tags: package.tags.uniqueNonEmptyValues,
      sections: sections,
      warnings: warnings
    )
  }

  private func packageDocumentPath(from data: Data, sourceName: String) throws -> String {
    try validateXML(data, sourceName: sourceName)
    let collector = EPUBContainerXMLCollector()
    let parser = XMLParser(data: data)
    parser.delegate = collector
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    guard parser.parse(), let path = collector.preferredRootfilePath?.nilIfEmpty else {
      let detail = parser.parserError?.localizedDescription ?? "container.xml 无有效 rootfile"
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（\(detail)）")
    }
    return try EPUBArchivePath.canonical(path, sourceName: sourceName)
  }

  private func packageDocument(from data: Data, sourceName: String) throws -> EPUBPackageDocument {
    try validateXML(data, sourceName: sourceName)
    let collector = EPUBPackageXMLCollector()
    let parser = XMLParser(data: data)
    parser.delegate = collector
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    guard parser.parse() else {
      let detail = parser.parserError?.localizedDescription ?? "OPF 元数据无效"
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（\(detail)）")
    }
    return collector.document
  }

  private func validateXML(_ data: Data, sourceName: String) throws {
    let prefix = String(decoding: data.prefix(16_384), as: UTF8.self).uppercased()
    guard !prefix.contains("<!DOCTYPE"), !prefix.contains("<!ENTITY") else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（EPUB 元数据包含不安全的 XML 声明）")
    }
  }

  private func resolvedArchivePath(
    href: String,
    relativeTo directory: [String],
    sourceName: String
  ) throws -> String {
    let withoutFragment = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? href
    let withoutQuery = withoutFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? withoutFragment
    let decoded = withoutQuery.removingPercentEncoding ?? withoutQuery
    let schemePattern = "^[A-Za-z][A-Za-z0-9+.-]*:"
    if decoded.range(of: schemePattern, options: .regularExpression) != nil {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（EPUB 章节引用了外部地址）")
    }
    let combined = (directory + [decoded]).joined(separator: "/")
    return try EPUBArchivePath.canonical(combined, sourceName: sourceName)
  }

  private func chapterText(from data: Data) -> (title: String?, text: String) {
    let source = String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .utf16)
      ?? String(data: data, encoding: .isoLatin1)
      ?? ""
    let sanitized = source
      .replacingOccurrences(
        of: "<script\\b[\\s\\S]*?</script>",
        with: " ",
        options: [.regularExpression, .caseInsensitive]
      )
      .replacingOccurrences(
        of: "<style\\b[\\s\\S]*?</style>",
        with: " ",
        options: [.regularExpression, .caseInsensitive]
      )
    let sanitizedData = Data(sanitized.utf8)
    let plainText: String
    if let attributed = try? NSAttributedString(
      data: sanitizedData,
      options: [
        .documentType: NSAttributedString.DocumentType.html,
        .characterEncoding: String.Encoding.utf8.rawValue,
      ],
      documentAttributes: nil
    ) {
      plainText = attributed.string
    } else {
      plainText = inlineHTMLText(sanitized)
    }

    let titleFragment = firstCapture(in: sanitized, pattern: "<h1\\b[^>]*>([\\s\\S]*?)</h1>")
      ?? firstCapture(in: sanitized, pattern: "<h2\\b[^>]*>([\\s\\S]*?)</h2>")
      ?? firstCapture(in: sanitized, pattern: "<title\\b[^>]*>([\\s\\S]*?)</title>")
    let title = titleFragment.flatMap { inlineHTMLText($0).nilIfEmpty }
    return (title, plainText.trimmedForPublishing)
  }

  private func inlineHTMLText(_ source: String) -> String {
    var value = source
      .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
      .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
      .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
      .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
      .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
      .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
      .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
      .replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
    let expression = try? NSRegularExpression(
      pattern: "&#(?:x([0-9A-Fa-f]+)|([0-9]+));",
      options: []
    )
    let matches = expression?.matches(
      in: value,
      range: NSRange(value.startIndex..<value.endIndex, in: value)
    ) ?? []
    for match in matches.reversed() {
      guard let fullRange = Range(match.range(at: 0), in: value) else { continue }
      let scalarValue: UInt32?
      if let hexRange = Range(match.range(at: 1), in: value) {
        scalarValue = UInt32(value[hexRange], radix: 16)
      } else if let decimalRange = Range(match.range(at: 2), in: value) {
        scalarValue = UInt32(value[decimalRange], radix: 10)
      } else {
        scalarValue = nil
      }
      guard let scalarValue, let scalar = UnicodeScalar(scalarValue) else { continue }
      value.replaceSubrange(fullRange, with: String(scalar))
    }
    return value.trimmedForPublishing
  }

  private func firstCapture(in text: String, pattern: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let match = expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
          ),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
  }
}

private struct EPUBManifestItem: Sendable {
  var href: String
  var mediaType: String
  var properties: Set<String>
}

private struct EPUBSpineItem: Sendable {
  var idref: String
  var isLinear: Bool
}

private struct EPUBPackageDocument: Sendable {
  var title: String?
  var authors: [String]
  var language: String?
  var summary: String?
  var tags: [String]
  var manifest: [String: EPUBManifestItem]
  var spine: [EPUBSpineItem]
}

private final class EPUBContainerXMLCollector: NSObject, XMLParserDelegate {
  private(set) var preferredRootfilePath: String?
  private var fallbackRootfilePath: String?

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    guard localName(elementName, qName) == "rootfile",
          let path = attributeDict["full-path"]?.nilIfEmpty else { return }
    if attributeDict["media-type"] == "application/oebps-package+xml" {
      preferredRootfilePath = preferredRootfilePath ?? path
    } else {
      fallbackRootfilePath = fallbackRootfilePath ?? path
    }
  }

  func parserDidEndDocument(_ parser: XMLParser) {
    preferredRootfilePath = preferredRootfilePath ?? fallbackRootfilePath
  }
}

private final class EPUBPackageXMLCollector: NSObject, XMLParserDelegate {
  private var metadataDepth = 0
  private var currentMetadataElement: String?
  private var metadataBuffer = ""
  private var title: String?
  private var authors: [String] = []
  private var language: String?
  private var summary: String?
  private var tags: [String] = []
  private var manifest: [String: EPUBManifestItem] = [:]
  private var spine: [EPUBSpineItem] = []

  var document: EPUBPackageDocument {
    EPUBPackageDocument(
      title: title,
      authors: authors,
      language: language,
      summary: summary,
      tags: tags,
      manifest: manifest,
      spine: spine
    )
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let name = localName(elementName, qName)
    if name == "metadata" {
      metadataDepth += 1
      return
    }
    if metadataDepth > 0, ["title", "creator", "language", "description", "subject"].contains(name) {
      currentMetadataElement = name
      metadataBuffer = ""
      return
    }
    if name == "item",
       let id = attributeDict["id"]?.nilIfEmpty,
       let href = attributeDict["href"]?.nilIfEmpty {
      manifest[id] = EPUBManifestItem(
        href: href,
        mediaType: attributeDict["media-type"]?.lowercased() ?? "",
        properties: Set(
          (attributeDict["properties"] ?? "")
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        )
      )
      return
    }
    if name == "itemref", let idref = attributeDict["idref"]?.nilIfEmpty {
      spine.append(EPUBSpineItem(
        idref: idref,
        isLinear: attributeDict["linear"]?.lowercased() != "no"
      ))
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard currentMetadataElement != nil else { return }
    metadataBuffer += string
  }

  func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
    guard currentMetadataElement != nil else { return }
    metadataBuffer += String(decoding: CDATABlock, as: UTF8.self)
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let name = localName(elementName, qName)
    if name == "metadata" {
      metadataDepth = max(0, metadataDepth - 1)
      return
    }
    guard name == currentMetadataElement else { return }
    let value = metadataBuffer.trimmedForPublishing
    switch name {
    case "title": title = title ?? value.nilIfEmpty
    case "creator": if !value.isEmpty { authors.append(value) }
    case "language": language = language ?? value.nilIfEmpty
    case "description": summary = summary ?? value.nilIfEmpty
    case "subject": if !value.isEmpty { tags.append(value) }
    default: break
    }
    currentMetadataElement = nil
    metadataBuffer = ""
  }
}

private func localName(_ elementName: String, _ qualifiedName: String?) -> String {
  let candidate = elementName.nilIfEmpty ?? qualifiedName ?? ""
  return candidate.split(separator: ":").last.map(String.init)?.lowercased() ?? ""
}

private extension Array where Element == String {
  var uniqueNonEmptyValues: [String] {
    var seen = Set<String>()
    return compactMap { value in
      let trimmed = value.trimmedForPublishing
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
      return trimmed
    }
  }
}

private enum EPUBArchivePath {
  static func canonical(_ rawPath: String, sourceName: String) throws -> String {
    guard !rawPath.isEmpty,
          !rawPath.hasPrefix("/"),
          !rawPath.hasPrefix("\\"),
          !rawPath.contains("\\"),
          !rawPath.contains("\0") else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（EPUB 包含不安全的内部路径）")
    }
    var components: [String] = []
    for component in rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
      if component.isEmpty || component == "." { continue }
      if component == ".." {
        guard !components.isEmpty else {
          throw KnowledgeLibraryError.unreadableSource("\(sourceName)（EPUB 内部路径越界）")
        }
        components.removeLast()
      } else {
        components.append(component)
      }
    }
    guard !components.isEmpty else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（EPUB 内部路径为空）")
    }
    return components.joined(separator: "/")
  }
}

private struct EPUBZIPEntry: Sendable {
  var path: String
  var flags: UInt16
  var compressionMethod: UInt16
  var crc32: UInt32
  var compressedSize: Int
  var uncompressedSize: Int
  var localHeaderOffset: Int
}

private struct EPUBZIPArchive: Sendable {
  private let data: Data
  private let sourceName: String
  private let maximumEntryBytes: Int
  private let entries: [String: EPUBZIPEntry]

  init(
    data: Data,
    sourceName: String,
    maximumEntryCount: Int,
    maximumExpandedBytes: Int,
    maximumEntryBytes: Int
  ) throws {
    self.data = data
    self.sourceName = sourceName
    self.maximumEntryBytes = maximumEntryBytes

    guard let endOffset = try data.lastEndOfCentralDirectoryOffset() else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（不是有效的 ZIP/EPUB 文件）")
    }
    let diskNumber = try data.uint16LE(at: endOffset + 4)
    let centralDirectoryDisk = try data.uint16LE(at: endOffset + 6)
    let entryCountOnDisk = try data.uint16LE(at: endOffset + 8)
    let entryCount = try data.uint16LE(at: endOffset + 10)
    let centralSize32 = try data.uint32LE(at: endOffset + 12)
    let centralOffset32 = try data.uint32LE(at: endOffset + 16)
    guard diskNumber == 0,
          centralDirectoryDisk == 0,
          entryCountOnDisk == entryCount,
          entryCount != UInt16.max,
          centralSize32 != UInt32.max,
          centralOffset32 != UInt32.max else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（不支持分卷或 ZIP64 EPUB）")
    }
    guard Int(entryCount) <= maximumEntryCount else {
      throw KnowledgeLibraryError.sourceLimitExceeded(
        "EPUB 内部文件超过 \(maximumEntryCount) 个：\(sourceName)"
      )
    }

    let centralOffset = Int(centralOffset32)
    let centralSize = Int(centralSize32)
    guard centralOffset >= 0,
          centralSize >= 0,
          centralOffset + centralSize <= endOffset else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（ZIP 中央目录越界）")
    }

    var parsed: [String: EPUBZIPEntry] = [:]
    var cursor = centralOffset
    var expandedBytes = 0
    for _ in 0..<Int(entryCount) {
      guard try data.uint32LE(at: cursor) == 0x0201_4B50 else {
        throw KnowledgeLibraryError.unreadableSource("\(sourceName)（ZIP 中央目录损坏）")
      }
      let flags = try data.uint16LE(at: cursor + 8)
      let method = try data.uint16LE(at: cursor + 10)
      let checksum = try data.uint32LE(at: cursor + 16)
      let compressedSize32 = try data.uint32LE(at: cursor + 20)
      let uncompressedSize32 = try data.uint32LE(at: cursor + 24)
      let nameLength = Int(try data.uint16LE(at: cursor + 28))
      let extraLength = Int(try data.uint16LE(at: cursor + 30))
      let commentLength = Int(try data.uint16LE(at: cursor + 32))
      let localOffset32 = try data.uint32LE(at: cursor + 42)
      guard compressedSize32 != UInt32.max,
            uncompressedSize32 != UInt32.max,
            localOffset32 != UInt32.max else {
        throw KnowledgeLibraryError.unreadableSource("\(sourceName)（不支持 ZIP64 EPUB）")
      }
      guard flags & 0x0001 == 0 else {
        throw KnowledgeLibraryError.unreadableSource("\(sourceName)（不支持加密 EPUB）")
      }
      guard method == 0 || method == 8 else {
        throw KnowledgeLibraryError.unreadableSource("\(sourceName)（包含不支持的 ZIP 压缩方式）")
      }

      let recordLength = 46 + nameLength + extraLength + commentLength
      guard recordLength >= 46, cursor + recordLength <= centralOffset + centralSize else {
        throw KnowledgeLibraryError.unreadableSource("\(sourceName)（ZIP 条目长度越界）")
      }
      let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
      guard let rawName = String(data: nameData, encoding: .utf8)
              ?? String(data: nameData, encoding: .isoLatin1) else {
        throw KnowledgeLibraryError.unreadableSource("\(sourceName)（ZIP 文件名编码无效）")
      }
      let path = try EPUBArchivePath.canonical(rawName, sourceName: sourceName)
      let compressedSize = Int(compressedSize32)
      let uncompressedSize = Int(uncompressedSize32)
      guard uncompressedSize <= maximumEntryBytes else {
        throw KnowledgeLibraryError.sourceLimitExceeded(
          "EPUB 内部单个文件超过 \(maximumEntryBytes / 1_024 / 1_024) MB：\(sourceName)"
        )
      }
      expandedBytes += uncompressedSize
      guard expandedBytes <= maximumExpandedBytes else {
        throw KnowledgeLibraryError.sourceLimitExceeded(
          "EPUB 解压后内容超过 \(maximumExpandedBytes / 1_024 / 1_024) MB：\(sourceName)"
        )
      }
      if uncompressedSize > 1_024 * 1_024, compressedSize > 0,
         uncompressedSize / compressedSize > 500 {
        throw KnowledgeLibraryError.sourceLimitExceeded("EPUB 包含异常压缩比例的文件：\(sourceName)")
      }
      guard parsed[path] == nil else {
        throw KnowledgeLibraryError.unreadableSource("\(sourceName)（EPUB 包含重复的内部路径）")
      }
      parsed[path] = EPUBZIPEntry(
        path: path,
        flags: flags,
        compressionMethod: method,
        crc32: checksum,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        localHeaderOffset: Int(localOffset32)
      )
      cursor += recordLength
    }
    self.entries = parsed
  }

  func textEntry(named path: String, maximumBytes: Int) throws -> String {
    let entryData = try entryData(named: path)
    guard entryData.count <= maximumBytes,
          let value = String(data: entryData, encoding: .utf8) else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（EPUB 文本条目无效：\(path)）")
    }
    return value
  }

  func entryData(named rawPath: String) throws -> Data {
    let path = try EPUBArchivePath.canonical(rawPath, sourceName: sourceName)
    guard let entry = entries[path] else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（缺少内部文件：\(path)）")
    }
    let localOffset = entry.localHeaderOffset
    guard try data.uint32LE(at: localOffset) == 0x0403_4B50 else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（ZIP 本地条目损坏）")
    }
    let localFlags = try data.uint16LE(at: localOffset + 6)
    let localMethod = try data.uint16LE(at: localOffset + 8)
    let localNameLength = Int(try data.uint16LE(at: localOffset + 26))
    let localExtraLength = Int(try data.uint16LE(at: localOffset + 28))
    guard localFlags & 0x0001 == 0, localMethod == entry.compressionMethod else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（ZIP 条目信息不一致）")
    }
    let payloadStart = localOffset + 30 + localNameLength + localExtraLength
    guard payloadStart >= 0,
          payloadStart + entry.compressedSize <= data.count else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（ZIP 压缩数据越界）")
    }
    let compressed = data.subdata(in: payloadStart..<(payloadStart + entry.compressedSize))
    let output: Data
    switch entry.compressionMethod {
    case 0:
      guard compressed.count == entry.uncompressedSize else {
        throw KnowledgeLibraryError.unreadableSource("\(sourceName)（ZIP 存储条目长度无效）")
      }
      output = compressed
    case 8:
      output = try inflateRaw(compressed, expectedSize: entry.uncompressedSize)
    default:
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（不支持的 ZIP 压缩方式）")
    }
    guard output.count == entry.uncompressedSize else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（ZIP 解压长度不一致）")
    }
    let checksum: uLong = output.withUnsafeBytes { bytes in
      let typed = bytes.bindMemory(to: Bytef.self)
      return crc32(0, typed.baseAddress, uInt(typed.count))
    }
    guard UInt32(truncatingIfNeeded: checksum) == entry.crc32 else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（ZIP 条目校验失败）")
    }
    return output
  }

  private func inflateRaw(_ compressed: Data, expectedSize: Int) throws -> Data {
    var stream = z_stream()
    let initialized = inflateInit2_(
      &stream,
      -MAX_WBITS,
      ZLIB_VERSION,
      Int32(MemoryLayout<z_stream>.size)
    )
    guard initialized == Z_OK else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（无法初始化 ZIP 解压器）")
    }
    defer { inflateEnd(&stream) }

    var output = Data(count: max(expectedSize, 1))
    let status = compressed.withUnsafeBytes { inputBytes in
      output.withUnsafeMutableBytes { outputBytes in
        let input = inputBytes.bindMemory(to: Bytef.self)
        let destination = outputBytes.bindMemory(to: Bytef.self)
        stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress)
        stream.avail_in = uInt(input.count)
        stream.next_out = destination.baseAddress
        stream.avail_out = uInt(destination.count)
        return inflate(&stream, Z_FINISH)
      }
    }
    guard status == Z_STREAM_END, Int(stream.total_out) == expectedSize else {
      throw KnowledgeLibraryError.unreadableSource("\(sourceName)（ZIP 解压失败）")
    }
    output.count = expectedSize
    return output
  }
}

private extension Data {
  func uint16LE(at offset: Int) throws -> UInt16 {
    guard offset >= 0, offset + 2 <= count else {
      throw KnowledgeLibraryError.unreadableSource("EPUB ZIP 数据越界")
    }
    return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
  }

  func uint32LE(at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= count else {
      throw KnowledgeLibraryError.unreadableSource("EPUB ZIP 数据越界")
    }
    return UInt32(self[offset])
      | (UInt32(self[offset + 1]) << 8)
      | (UInt32(self[offset + 2]) << 16)
      | (UInt32(self[offset + 3]) << 24)
  }

  func lastEndOfCentralDirectoryOffset() throws -> Int? {
    guard count >= 22 else { return nil }
    let lowerBound = Swift.max(0, count - 22 - 65_535)
    var cursor = count - 22
    while cursor >= lowerBound {
      if try uint32LE(at: cursor) == 0x0605_4B50 {
        let commentLength = Int(try uint16LE(at: cursor + 20))
        if cursor + 22 + commentLength == count {
          return cursor
        }
      }
      if cursor == 0 { break }
      cursor -= 1
    }
    return nil
  }
}
