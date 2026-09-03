import Foundation

/// A token-aware repair helper for local relative links reported by
/// ``SiteLinkAuditService``. It deliberately has no filesystem write or UI
/// dependency: callers choose a file, obtain a replacement plan, and persist
/// the returned Markdown through their normal draft-save path.
public struct ContentHealthBrokenLinkQuickFixService: Sendable {
  public init() {}

  /// Returns whether a reported target can be replaced by a repository-local
  /// resource picker result.
  public func isRepairableLocalRelativePath(
    _ target: String,
    syntax: SiteLinkSyntaxKind
  ) -> Bool {
    guard syntax != .wiki else { return false }
    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("#") else {
      return false
    }
    let path = pathWithoutQueryOrFragment(trimmed)
    guard !path.isEmpty else { return false }
    return URLComponents(string: trimmed)?.scheme == nil
  }

  /// Produces a safe, repository-contained replacement target for Markdown.
  /// The selected file's resolved path must be a regular file inside the
  /// resolved repository root, so a symlink cannot escape the repository.
  public func resourcePlan(
    selectedURL: URL,
    repositoryRootURL: URL,
    sourceRepositoryPath: String
  ) throws -> ContentHealthBrokenLinkQuickFixResourcePlan {
    let root = canonicalFileURL(repositoryRootURL)
    let selected = canonicalFileURL(selectedURL)
    guard isDescendant(selected, of: root) else {
      throw ContentHealthBrokenLinkQuickFixError.selectedResourceOutsideRepository
    }
    guard FileManager.default.fileExists(atPath: selected.path) else {
      throw ContentHealthBrokenLinkQuickFixError.selectedResourceDoesNotExist
    }
    guard try selected.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
      throw ContentHealthBrokenLinkQuickFixError.selectedResourceIsNotRegularFile
    }

    let sourcePath = try normalizedSourceRepositoryPath(sourceRepositoryPath)
    guard let selectedRepositoryPath = relativePath(of: selected, root: root) else {
      throw ContentHealthBrokenLinkQuickFixError.selectedResourceOutsideRepository
    }
    let sourceDirectory = URL(fileURLWithPath: "/" + sourcePath)
      .deletingLastPathComponent()
      .path
    let relativeTarget = relativePOSIXPath(
      fromDirectoryPath: sourceDirectory,
      toPath: "/" + selectedRepositoryPath
    )
    return ContentHealthBrokenLinkQuickFixResourcePlan(
      selectedRepositoryPath: selectedRepositoryPath,
      replacementTarget: percentEncodedMarkdownTarget(relativeTarget)
    )
  }

  /// Selects exact broken-link tokens, rather than searching Markdown text.
  /// This means repeated targets are all repaired, while code blocks and plain
  /// text remain untouched because they were never reported as references.
  public func replacementPlan(
    bodyMarkdown: String,
    references: [SiteLinkReference],
    sourceDraftID: UUID,
    oldTarget: String,
    newTarget: String
  ) throws -> ContentHealthBrokenLinkQuickFixPlan {
    guard isRepairableLocalRelativePath(oldTarget, syntax: .markdown) else {
      throw ContentHealthBrokenLinkQuickFixError.targetIsNotRepairable
    }
    guard isRepairableLocalRelativePath(newTarget, syntax: .markdown) else {
      throw ContentHealthBrokenLinkQuickFixError.replacementTargetIsNotLocalRelativePath
    }
    let oldPath = pathWithoutQueryOrFragment(oldTarget)
    let matching = references.filter {
      $0.resolution == .brokenInternal
        && $0.sourceDraftID == sourceDraftID
        && $0.target == oldTarget
        && isRepairableLocalRelativePath($0.target, syntax: $0.syntax)
    }
    guard !matching.isEmpty else {
      throw ContentHealthBrokenLinkQuickFixError.noMatchingBrokenReferences
    }

    let source = bodyMarkdown as NSString
    let replacements = try matching.map { reference in
      let range = reference.targetUTF16Range
      guard range.location >= 0, NSMaxRange(range) <= source.length else {
        throw ContentHealthBrokenLinkQuickFixError.invalidTargetRange
      }
      guard source.substring(with: range) == oldPath else {
        throw ContentHealthBrokenLinkQuickFixError.targetRangeDoesNotMatch
      }
      return ContentHealthBrokenLinkQuickFixReplacement(
        utf16Location: range.location,
        utf16Length: range.length
      )
    }
    return ContentHealthBrokenLinkQuickFixPlan(
      sourceDraftID: sourceDraftID,
      oldTarget: oldTarget,
      replacementTarget: newTarget,
      replacements: replacements
    )
  }

  /// Applies a previously validated plan from the end of the UTF-16 buffer.
  public func apply(
    _ plan: ContentHealthBrokenLinkQuickFixPlan,
    to bodyMarkdown: String
  ) throws -> ContentHealthBrokenLinkQuickFixResult {
    let source = bodyMarkdown as NSString
    let oldPath = pathWithoutQueryOrFragment(plan.oldTarget)
    for replacement in plan.replacements {
      let range = replacement.nsRange
      guard range.location >= 0, NSMaxRange(range) <= source.length else {
        throw ContentHealthBrokenLinkQuickFixError.invalidTargetRange
      }
      guard source.substring(with: range) == oldPath else {
        throw ContentHealthBrokenLinkQuickFixError.targetRangeDoesNotMatch
      }
    }

    var repaired = bodyMarkdown
    for replacement in plan.replacements.sorted(by: { $0.utf16Location > $1.utf16Location }) {
      repaired = (repaired as NSString).replacingCharacters(
        in: replacement.nsRange,
        with: plan.replacementTarget
      )
    }
    return ContentHealthBrokenLinkQuickFixResult(
      sourceDraftID: plan.sourceDraftID,
      bodyMarkdown: repaired,
      replacementCount: plan.replacements.count,
      replacementTarget: plan.replacementTarget
    )
  }

  private func normalizedSourceRepositoryPath(_ sourceRepositoryPath: String) throws -> String {
    let normalized =
      sourceRepositoryPath
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\", with: "/")
    guard !normalized.isEmpty, !normalized.hasPrefix("/") else {
      throw ContentHealthBrokenLinkQuickFixError.invalidSourceRepositoryPath
    }
    let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
    guard !components.isEmpty,
      !components.contains("."),
      !components.contains("..")
    else {
      throw ContentHealthBrokenLinkQuickFixError.invalidSourceRepositoryPath
    }
    return components.joined(separator: "/")
  }

  private func canonicalFileURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }

  private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
    let rootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
    return candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/")
  }

  private func relativePath(of candidate: URL, root: URL) -> String? {
    let rootPath = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
    guard candidate.path.hasPrefix(rootPath + "/") else { return nil }
    return String(candidate.path.dropFirst(rootPath.count + 1))
  }

  private func relativePOSIXPath(fromDirectoryPath source: String, toPath destination: String)
    -> String
  {
    let sourceComponents = source.split(separator: "/").map(String.init)
    let destinationComponents = destination.split(separator: "/").map(String.init)
    var sharedCount = 0
    while sharedCount < sourceComponents.count,
      sharedCount < destinationComponents.count,
      sourceComponents[sharedCount] == destinationComponents[sharedCount]
    {
      sharedCount += 1
    }
    let upward = Array(repeating: "..", count: sourceComponents.count - sharedCount)
    let downward = Array(destinationComponents.dropFirst(sharedCount))
    let components = upward + downward
    return components.isEmpty ? "." : components.joined(separator: "/")
  }

  private func percentEncodedMarkdownTarget(_ value: String) -> String {
    var allowed = CharacterSet()
    allowed.insert(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  private func pathWithoutQueryOrFragment(_ target: String) -> String {
    let beforeFragment =
      target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
      .first ?? ""
    return String(
      beforeFragment.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first
        ?? ""
    )
  }
}

public struct ContentHealthBrokenLinkQuickFixResourcePlan: Hashable, Sendable {
  public var selectedRepositoryPath: String
  public var replacementTarget: String

  public init(selectedRepositoryPath: String, replacementTarget: String) {
    self.selectedRepositoryPath = selectedRepositoryPath
    self.replacementTarget = replacementTarget
  }
}

public struct ContentHealthBrokenLinkQuickFixReplacement: Hashable, Sendable {
  public var utf16Location: Int
  public var utf16Length: Int

  public init(utf16Location: Int, utf16Length: Int) {
    self.utf16Location = utf16Location
    self.utf16Length = utf16Length
  }

  fileprivate var nsRange: NSRange {
    NSRange(location: utf16Location, length: utf16Length)
  }
}

public struct ContentHealthBrokenLinkQuickFixPlan: Hashable, Sendable {
  public var sourceDraftID: UUID
  public var oldTarget: String
  public var replacementTarget: String
  public var replacements: [ContentHealthBrokenLinkQuickFixReplacement]

  public init(
    sourceDraftID: UUID,
    oldTarget: String,
    replacementTarget: String,
    replacements: [ContentHealthBrokenLinkQuickFixReplacement]
  ) {
    self.sourceDraftID = sourceDraftID
    self.oldTarget = oldTarget
    self.replacementTarget = replacementTarget
    self.replacements = replacements
  }
}

public struct ContentHealthBrokenLinkQuickFixResult: Hashable, Sendable {
  public var sourceDraftID: UUID
  public var bodyMarkdown: String
  public var replacementCount: Int
  public var replacementTarget: String

  public init(
    sourceDraftID: UUID,
    bodyMarkdown: String,
    replacementCount: Int,
    replacementTarget: String
  ) {
    self.sourceDraftID = sourceDraftID
    self.bodyMarkdown = bodyMarkdown
    self.replacementCount = replacementCount
    self.replacementTarget = replacementTarget
  }
}

public enum ContentHealthBrokenLinkQuickFixError: Error, Hashable, Sendable {
  case targetIsNotRepairable
  case replacementTargetIsNotLocalRelativePath
  case noMatchingBrokenReferences
  case invalidTargetRange
  case targetRangeDoesNotMatch
  case invalidSourceRepositoryPath
  case selectedResourceDoesNotExist
  case selectedResourceIsNotRegularFile
  case selectedResourceOutsideRepository
}
