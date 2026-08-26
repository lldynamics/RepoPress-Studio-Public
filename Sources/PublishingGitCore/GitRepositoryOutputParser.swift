import Foundation
import PublishingCoreSupport

/// Parses machine-readable output from local Git commands without executing
/// Git or accessing a repository. Callers supply a fallback date so malformed
/// or missing dates remain deterministic in tests and other pure consumers.
public struct GitRepositoryOutputParser: Sendable {
  public init() {}

  public func parseBranchListLine(_ line: String) -> RepositoryBranch? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }

    let parts = trimmed
      .split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
      .map(String.init)
    guard let name = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
      return nil
    }

    let head = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    let upstream = parts.count > 2
      ? parts[2].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      : nil
    return RepositoryBranch(name: name, isCurrent: head == "*", upstreamName: upstream)
  }

  public func parseRecentCommitLine(
    _ line: String,
    fallbackDate: Date
  ) -> RepositoryCommitInfo? {
    let parts = line
      .split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
      .map(String.init)
    guard parts.count == 4 else {
      return nil
    }

    let sha = parts[0].trimmedForPublishing
    let author = parts[1].trimmedForPublishing
    let dateText = parts[2].trimmedForPublishing
    let message = parts[3].trimmedForPublishing
    guard !sha.isEmpty, !author.isEmpty, !message.isEmpty else {
      return nil
    }

    return RepositoryCommitInfo(
      sha: sha,
      shortSHA: String(sha.prefix(8)),
      author: author,
      date: parseGitDate(dateText, fallbackDate: fallbackDate),
      message: message
    )
  }

  public func parseGitDate(_ text: String, fallbackDate: Date) -> Date {
    let trimmedText = text.trimmedForPublishing
    guard !trimmedText.isEmpty else {
      return fallbackDate
    }

    if let legacyGitDate = normalizedLegacyGitDate(trimmedText),
       let date = parseISO8601Date(legacyGitDate) {
      return date
    }

    if let date = parseISO8601Date(trimmedText) {
      return date
    }

    return fallbackDate
  }

  private func parseISO8601Date(_ text: String) -> Date? {
    guard hasValidISO8601DateTimeComponents(in: text),
          hasValidISO8601TimeZone(in: text)
    else {
      return nil
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: text) {
      return date
    }

    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }

  private func hasValidISO8601DateTimeComponents(in text: String) -> Bool {
    let bytes = Array(text.utf8)
    guard bytes.count >= 19,
          [4, 7].allSatisfy({ bytes[$0] == 0x2D }),
          bytes[10] == 0x54,
          [13, 16].allSatisfy({ bytes[$0] == 0x3A }),
          bytes[0..<4].allSatisfy(isASCIIDigit),
          bytes[5..<7].allSatisfy(isASCIIDigit),
          bytes[8..<10].allSatisfy(isASCIIDigit),
          bytes[11..<13].allSatisfy(isASCIIDigit),
          bytes[14..<16].allSatisfy(isASCIIDigit),
          bytes[17..<19].allSatisfy(isASCIIDigit)
    else {
      return false
    }

    let month = Int(String(decoding: bytes[5..<7], as: UTF8.self)) ?? 0
    let day = Int(String(decoding: bytes[8..<10], as: UTF8.self)) ?? 0
    let hour = Int(String(decoding: bytes[11..<13], as: UTF8.self)) ?? -1
    let minute = Int(String(decoding: bytes[14..<16], as: UTF8.self)) ?? -1
    let second = Int(String(decoding: bytes[17..<19], as: UTF8.self)) ?? -1
    guard month >= 1, month <= 12,
          day >= 1,
          day <= daysInMonth(month: month, year: Int(String(decoding: bytes[0..<4], as: UTF8.self)) ?? 0),
          hour <= 23,
          minute <= 59,
          second <= 59
    else {
      return false
    }

    return true
  }

  private func daysInMonth(month: Int, year: Int) -> Int {
    switch month {
    case 2:
      let isLeapYear = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
      return isLeapYear ? 29 : 28
    case 4, 6, 9, 11:
      return 30
    default:
      return 31
    }
  }

  private func normalizedLegacyGitDate(_ text: String) -> String? {
    let bytes = Array(text.utf8)
    guard bytes.count == 25,
          bytes[10] == 0x20,
          bytes[19] == 0x20,
          bytes[20] == 0x2B || bytes[20] == 0x2D,
          [4, 7].allSatisfy({ bytes[$0] == 0x2D }),
          [13, 16].allSatisfy({ bytes[$0] == 0x3A }),
          bytes[21...24].allSatisfy(isASCIIDigit)
    else {
      return nil
    }

    guard bytes[0..<4].allSatisfy(isASCIIDigit),
          bytes[5..<7].allSatisfy(isASCIIDigit),
          bytes[8..<10].allSatisfy(isASCIIDigit),
          bytes[11..<13].allSatisfy(isASCIIDigit),
          bytes[14..<16].allSatisfy(isASCIIDigit),
          bytes[17..<19].allSatisfy(isASCIIDigit)
    else {
      return nil
    }

    let offsetHours = Int(String(decoding: bytes[21..<23], as: UTF8.self)) ?? -1
    let offsetMinutes = Int(String(decoding: bytes[23..<25], as: UTF8.self)) ?? -1
    guard offsetHours <= 23, offsetMinutes <= 59 else {
      return nil
    }

    let date = String(decoding: bytes[0..<10], as: UTF8.self)
    let time = String(decoding: bytes[11..<19], as: UTF8.self)
    let sign = String(decoding: bytes[20...20], as: UTF8.self)
    let hours = String(decoding: bytes[21..<23], as: UTF8.self)
    let minutes = String(decoding: bytes[23..<25], as: UTF8.self)
    return "\(date)T\(time)\(sign)\(hours):\(minutes)"
  }

  private func hasValidISO8601TimeZone(in text: String) -> Bool {
    guard let timeSeparator = text.firstIndex(of: "T") else {
      return false
    }

    if text.hasSuffix("Z") {
      return true
    }

    guard let timezoneStart = text.lastIndex(where: { $0 == "+" || $0 == "-" }),
          timezoneStart > timeSeparator
    else {
      return false
    }

    let timezone = Array(text[timezoneStart...].utf8)
    guard timezone.count == 6,
          timezone[0] == 0x2B || timezone[0] == 0x2D,
          timezone[3] == 0x3A,
          timezone[1...2].allSatisfy(isASCIIDigit),
          timezone[4...5].allSatisfy(isASCIIDigit)
    else {
      return false
    }

    let offsetHours = Int(String(decoding: timezone[1...2], as: UTF8.self)) ?? -1
    let offsetMinutes = Int(String(decoding: timezone[4...5], as: UTF8.self)) ?? -1
    return offsetHours <= 23 && offsetMinutes <= 59
  }

  private func isASCIIDigit(_ byte: UInt8) -> Bool {
    byte >= 0x30 && byte <= 0x39
  }

  public func parseBranchStatusLine(_ line: String) -> RepositoryBranchStatus? {
    let text = line.replacingOccurrences(of: "## ", with: "")
    if text.hasPrefix("HEAD ") || text == "HEAD (no branch)" {
      return RepositoryBranchStatus(branchName: nil, upstreamName: nil, isDetached: true)
    }

    if text.hasPrefix("No commits yet on ") {
      let branch = text.replacingOccurrences(of: "No commits yet on ", with: "")
      return RepositoryBranchStatus(branchName: branch.nilIfEmpty, upstreamName: nil)
    }

    let parts = text.components(separatedBy: "...")
    guard let branchName = parts.first?.nilIfEmpty else {
      return nil
    }

    guard parts.count > 1 else {
      return RepositoryBranchStatus(branchName: branchName, upstreamName: nil)
    }

    let upstreamAndSync = parts[1]
    if let bracketStart = upstreamAndSync.firstIndex(of: "[") {
      let upstream = String(upstreamAndSync[..<bracketStart]).trimmedForPublishing.nilIfEmpty
      let syncText = String(upstreamAndSync[bracketStart...])
      return RepositoryBranchStatus(
        branchName: branchName,
        upstreamName: upstream,
        aheadCount: parseSyncCount(label: "ahead", in: syncText),
        behindCount: parseSyncCount(label: "behind", in: syncText)
      )
    }

    return RepositoryBranchStatus(
      branchName: branchName,
      upstreamName: upstreamAndSync.trimmedForPublishing.nilIfEmpty
    )
  }

  public func parseSyncCount(label: String, in text: String) -> Int {
    let escapedLabel = NSRegularExpression.escapedPattern(for: label)
    let pattern = "\(escapedLabel) ([0-9]+)"
    guard
      let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: text,
        range: NSRange(text.startIndex..<text.endIndex, in: text)
      ),
      let range = Range(match.range(at: 1), in: text)
    else {
      return 0
    }
    return Int(text[range]) ?? 0
  }
}
