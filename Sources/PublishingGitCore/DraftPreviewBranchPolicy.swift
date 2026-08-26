import Foundation
import PublishingDomainContracts

/// Builds the stable branch used by a single article's remote preview.
///
/// The preview branch is deliberately derived from the package's existing
/// review branch. That keeps the branch stable across retries while avoiding
/// adding a second slug field to the persisted publish-package contract.
public enum DraftPreviewBranchPolicy {
  public static let prefix = "draft/"
  public static let maximumSlugLength = 80

  public static func branchName(slug: String) -> String {
    let folded = slug
      .precomposedStringWithCanonicalMapping
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))

    var slugCharacters: [Character] = []
    var needsSeparator = false
    for scalar in folded.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        if needsSeparator && !slugCharacters.isEmpty {
          slugCharacters.append("-")
        }
        slugCharacters.append(contentsOf: String(scalar).lowercased())
        needsSeparator = false
      } else {
        needsSeparator = true
      }
    }

    var sanitized = String(slugCharacters)
      .split(separator: "-")
      .joined(separator: "-")
    if sanitized.isEmpty {
      sanitized = "article"
    }
    if sanitized.count > maximumSlugLength {
      sanitized = String(sanitized.prefix(maximumSlugLength))
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    return prefix + (sanitized.isEmpty ? "article" : sanitized)
  }

  public static func branchName(for package: PublishPackage) -> String {
    let reviewStem = package.reviewBranchName
      .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
      .last
      .map(String.init)
      ?? ""
    let slug = removingPublicationDateSuffix(from: reviewStem)
    return branchName(slug: slug.isEmpty ? package.title : slug)
  }

  private static func removingPublicationDateSuffix(from value: String) -> String {
    guard value.count > 9 else { return value }
    let suffixStart = value.index(value.endIndex, offsetBy: -9)
    let suffix = value[suffixStart...]
    guard suffix.first == "-", suffix.dropFirst().allSatisfy(\.isNumber) else {
      return value
    }
    return String(value[..<suffixStart])
  }
}

public extension PublishPackage {
  /// Stable `draft/<slug>` branch used by the single-draft preview action.
  var draftPreviewBranchName: String {
    DraftPreviewBranchPolicy.branchName(for: self)
  }
}
