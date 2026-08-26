import Foundation

/// Performs the security-sensitive checks that Foundation's XMLParser does
/// not expose as parser configuration. The input is bounded by each caller,
/// but the expanded event stream still needs an independent character and
/// nesting budget.
package enum UntrustedXMLParserGuard {
  package struct Limits: Sendable {
    let maximumCharacterCount: Int
    let maximumElementDepth: Int

    package init(maximumCharacterCount: Int, maximumElementDepth: Int) {
      self.maximumCharacterCount = max(1, maximumCharacterCount)
      self.maximumElementDepth = max(1, maximumElementDepth)
    }
  }

  package enum Failure: Error, Equatable {
    case forbiddenDeclaration
    case characterLimitExceeded
    case elementDepthExceeded
    case cancelled
  }

  package static func validate(data: Data, limits: Limits) throws {
    guard !data.isEmpty else { return }
    guard !containsForbiddenDeclaration(in: data) else {
      throw Failure.forbiddenDeclaration
    }

    let monitor = Monitor(limits: limits)
    let parser = XMLParser(data: data)
    parser.delegate = monitor
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    _ = parser.parse()
    if let failure = monitor.failure {
      throw failure
    }
  }

  private static func containsForbiddenDeclaration(in data: Data) -> Bool {
    if containsASCIIDeclaration(in: data) {
      return true
    }

    // XMLParser accepts UTF-16 documents as well. Their ASCII declaration
    // bytes are interleaved with NULs, so inspect the decoded document too;
    // this remains a full-document scan rather than a fixed prefix check.
    let encoding: String.Encoding?
    if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
      encoding = .utf32LittleEndian
    } else if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
      encoding = .utf32BigEndian
    } else if data.starts(with: [0xFF, 0xFE]) {
      encoding = .utf16LittleEndian
    } else if data.starts(with: [0xFE, 0xFF]) {
      encoding = .utf16BigEndian
    } else if data.count >= 4 {
      let prefix = Array(data.prefix(4))
      if prefix == [0x3C, 0x00, 0x00, 0x00] {
        encoding = .utf32LittleEndian
      } else if prefix == [0x00, 0x00, 0x00, 0x3C] {
        encoding = .utf32BigEndian
      } else if prefix[0] == 0x3C, prefix[1] == 0x00 {
        encoding = .utf16LittleEndian
      } else if prefix[0] == 0x00, prefix[1] == 0x3C {
        encoding = .utf16BigEndian
      } else {
        encoding = nil
      }
    } else {
      encoding = nil
    }

    guard let encoding,
          let document = String(data: data, encoding: encoding) else { return false }
    return containsForbiddenDeclaration(in: document)
  }

  private static func containsASCIIDeclaration(in data: Data) -> Bool {
    let doctype = Array("<!DOCTYPE".utf8)
    let entity = Array("<!ENTITY".utf8)
    return data.withUnsafeBytes { rawBuffer in
      guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
        return false
      }
      guard rawBuffer.count >= min(doctype.count, entity.count) else { return false }
      for index in 0..<rawBuffer.count {
        guard bytes[index] == 0x3C else { continue }
        if matches(doctype, in: bytes, count: rawBuffer.count, at: index)
          || matches(entity, in: bytes, count: rawBuffer.count, at: index) {
          return true
        }
      }
      return false
    }
  }

  private static func matches(
    _ pattern: [UInt8],
    in bytes: UnsafePointer<UInt8>,
    count: Int,
    at index: Int
  ) -> Bool {
    guard index + pattern.count <= count else { return false }
    for offset in pattern.indices {
      let value = bytes[index + offset]
      let uppercased = value >= 0x61 && value <= 0x7A ? value - 0x20 : value
      guard uppercased == pattern[offset] else { return false }
    }
    return true
  }

  private static func containsForbiddenDeclaration(in document: String) -> Bool {
    document.range(of: "<!DOCTYPE", options: [.caseInsensitive]) != nil
      || document.range(of: "<!ENTITY", options: [.caseInsensitive]) != nil
  }

  private final class Monitor: NSObject, XMLParserDelegate {
    private let limits: Limits
    private var depth = 0
    private var characterCount = 0
    private(set) var failure: Failure?

    init(limits: Limits) {
      self.limits = limits
    }

    func parser(
      _ parser: XMLParser,
      didStartElement elementName: String,
      namespaceURI: String?,
      qualifiedName qName: String?,
      attributes attributeDict: [String: String] = [:]
    ) {
      guard failure == nil else { return }
      guard !Task.isCancelled else {
        abort(parser, with: .cancelled)
        return
      }
      depth += 1
      guard depth <= limits.maximumElementDepth else {
        abort(parser, with: .elementDepthExceeded)
        return
      }
      add(attributeDict.values.reduce(into: 0) { result, value in
        let (next, overflow) = result.addingReportingOverflow(value.count)
        result = overflow ? Int.max : next
      }, to: parser, failure: .characterLimitExceeded)
    }

    func parser(
      _ parser: XMLParser,
      didEndElement elementName: String,
      namespaceURI: String?,
      qualifiedName qName: String?
    ) {
      guard failure == nil else { return }
      depth = max(0, depth - 1)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      add(string.count, to: parser, failure: .characterLimitExceeded)
    }

    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) {
      add(whitespaceString.count, to: parser, failure: .characterLimitExceeded)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
      add(
        String(decoding: CDATABlock, as: UTF8.self).count,
        to: parser,
        failure: .characterLimitExceeded
      )
    }

    func parser(_ parser: XMLParser, foundComment comment: String) {
      add(comment.count, to: parser, failure: .characterLimitExceeded)
    }

    func parser(
      _ parser: XMLParser,
      foundProcessingInstructionWithTarget target: String,
      data: String?
    ) {
      add(target.count + (data?.count ?? 0), to: parser, failure: .characterLimitExceeded)
    }

    func parser(
      _ parser: XMLParser,
      foundNotationDeclarationWithName name: String,
      publicID: String?,
      systemID: String?
    ) {
      abort(parser, with: .forbiddenDeclaration)
    }

    func parser(
      _ parser: XMLParser,
      foundUnparsedEntityDeclarationWithName name: String,
      publicID: String?,
      systemID: String?,
      notationName: String?
    ) {
      abort(parser, with: .forbiddenDeclaration)
    }

    func parser(
      _ parser: XMLParser,
      foundAttributeDeclarationWithName attributeName: String,
      forElement elementName: String,
      type: String?,
      defaultValue: String?
    ) {
      abort(parser, with: .forbiddenDeclaration)
    }

    func parser(
      _ parser: XMLParser,
      foundElementDeclarationWithName elementName: String,
      model: String
    ) {
      abort(parser, with: .forbiddenDeclaration)
    }

    func parser(
      _ parser: XMLParser,
      foundInternalEntityDeclarationWithName name: String,
      value: String?
    ) {
      abort(parser, with: .forbiddenDeclaration)
    }

    func parser(
      _ parser: XMLParser,
      foundExternalEntityDeclarationWithName name: String,
      publicID: String?,
      systemID: String?
    ) {
      abort(parser, with: .forbiddenDeclaration)
    }

    func parser(
      _ parser: XMLParser,
      resolveExternalEntityName name: String,
      systemID: String?
    ) -> Data? {
      abort(parser, with: .forbiddenDeclaration)
      return nil
    }

    private func add(_ count: Int, to parser: XMLParser, failure: Failure) {
      guard self.failure == nil else { return }
      guard !Task.isCancelled else {
        abort(parser, with: .cancelled)
        return
      }
      let (next, overflow) = characterCount.addingReportingOverflow(count)
      guard !overflow, next <= limits.maximumCharacterCount else {
        abort(parser, with: failure)
        return
      }
      characterCount = next
    }

    private func abort(_ parser: XMLParser, with failure: Failure) {
      guard self.failure == nil else { return }
      self.failure = failure
      parser.abortParsing()
    }
  }
}
