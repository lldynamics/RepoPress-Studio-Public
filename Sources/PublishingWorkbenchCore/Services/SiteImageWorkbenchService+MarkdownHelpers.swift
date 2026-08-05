import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(Darwin)
import Darwin
#endif
extension SiteImageWorkbenchService {
  func isJPEGFilename(_ filename: String) -> Bool {
    let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
    return ext == "jpg" || ext == "jpeg"
  }

  func isSVGFilename(_ filename: String) -> Bool {
    URL(fileURLWithPath: filename).pathExtension.lowercased() == "svg"
  }

  func stableSummaryIssues(
    _ issues: [ImageWorkbenchIssue],
    draftID: UUID
  ) -> [ImageWorkbenchIssue] {
    issues.enumerated().map { offset, issue in
      var stableIssue = issue
      let identity = [
        draftID.uuidString,
        issue.attachmentID?.uuidString ?? "",
        issue.severity.rawValue,
        issue.title,
        issue.message,
        String(offset),
      ].joined(separator: "\u{1F}")
      var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
      bytes[6] = (bytes[6] & 0x0F) | 0x50
      bytes[8] = (bytes[8] & 0x3F) | 0x80
      stableIssue.id = UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      ))
      return stableIssue
    }
  }

  func isWebPConvertibleFilename(_ filename: String) -> Bool {
    switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
    case "jpg", "jpeg", "png", "heic", "tif", "tiff", "avif":
      return true
    default:
      return false
    }
  }

  func isResizableRasterFilename(_ filename: String) -> Bool {
    switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
    case "jpg", "jpeg", "png", "webp", "heic", "tif", "tiff", "avif":
      return true
    default:
      return false
    }
  }

  func isCroppableRasterFilename(_ filename: String) -> Bool {
    isResizableRasterFilename(filename)
  }

  func pathByReplacingExtension(_ path: String, with newExtension: String) -> String {
    let trimmed = path.trimmedForPublishing
    let namespace = trimmed as NSString
    let basePath = namespace.deletingPathExtension
    guard !basePath.isEmpty else {
      return trimmed
    }
    return basePath + ".\(newExtension)"
  }

  func optimizedSVGText(_ text: String) -> String {
    var optimized = text
    optimized = optimized.replacingOccurrences(
      of: #"(?s)<!--.*?-->"#,
      with: "",
      options: .regularExpression
    )
    optimized = optimized.replacingOccurrences(
      of: #">\s+<"#,
      with: "><",
      options: .regularExpression
    )
    optimized = optimized
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .joined(separator: "\n")
    return optimized.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func humanizedFilename(_ filename: String) -> String {
    let stem = URL(fileURLWithPath: filename)
      .deletingPathExtension()
      .lastPathComponent
    return stem
      .replacingOccurrences(of: "-", with: " ")
      .replacingOccurrences(of: "_", with: " ")
      .trimmedForPublishing
      .nilIfEmpty ?? "图片"
  }

  func localMarkdownImagePathCounts(in markdown: String) -> [String: Int] {
    let pattern = #"!\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return [:]
    }

    let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    let paths = regex.matches(in: markdown, range: range).compactMap { match -> String? in
      guard let matchRange = Range(match.range(at: 1), in: markdown) else { return nil }
      let path = String(markdown[matchRange])
      guard !path.hasPrefix("http://"), !path.hasPrefix("https://"), !path.hasPrefix("data:") else {
        return nil
      }
      return path
    }
    return paths.reduce(into: [:]) { counts, path in
      counts[path, default: 0] += 1
    }
  }

  func duplicateCounts(_ values: [String?]) -> [String: Int] {
    values.compactMap { $0 }.reduce(into: [:]) { counts, value in
      counts[value, default: 0] += 1
    }
  }

  func normalizedPublishPath(_ path: String) -> String? {
    path.trimmedForPublishing.nilIfEmpty
  }

  func normalizedSourcePath(_ path: String?) -> String? {
    guard let path = path?.trimmedForPublishing.nilIfEmpty else {
      return nil
    }
    return URL(fileURLWithPath: path).standardizedFileURL.path
  }

  func replaceEmptyMarkdownAlt(
    in markdown: String,
    imagePath: String,
    altText: String
  ) -> (text: String, replacementCount: Int) {
    let pattern = #"!\[([^\]]*)\]\("#
      + NSRegularExpression.escapedPattern(for: imagePath)
      + #"\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return (markdown, 0)
    }

    var updated = markdown
    var replacementCount = 0
    let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    let matches = regex.matches(in: markdown, range: range)

    for match in matches.reversed() {
      guard
        let fullRange = Range(match.range(at: 0), in: updated),
        let altRange = Range(match.range(at: 1), in: updated)
      else {
        continue
      }

      if updated[altRange].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        updated.replaceSubrange(fullRange, with: "![\(altText)](\(imagePath))")
        replacementCount += 1
      }
    }

    return (updated, replacementCount)
  }

  func replaceMarkdownImagePath(
    in markdown: String,
    oldPath: String,
    newPath: String
  ) -> String {
    guard oldPath != newPath else {
      return markdown
    }
    let pattern = #"(!\[[^\]]*\]\()"#
      + NSRegularExpression.escapedPattern(for: oldPath)
      + #"((?:\s+"[^"]*")?\))"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return markdown
    }

    let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    return regex.stringByReplacingMatches(
      in: markdown,
      range: range,
      withTemplate: "$1\(newPath)$2"
    )
  }
}
