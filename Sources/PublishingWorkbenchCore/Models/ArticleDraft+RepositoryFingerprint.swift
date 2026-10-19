import CryptoKit
import Foundation

extension ArticleDraft {
  public static func repositoryDocumentDigest(_ document: String) -> String {
    SHA256.hash(data: Data(document.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static let fingerprintEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
  }()

  /// Stable content identity for fields controlled by repository Markdown.
  /// Runtime identifiers, timestamps and remote SHAs are excluded so repeated
  /// imports of the same document remain a no-op.
  public var repositoryContentFingerprint: String {
    let coverRepositoryPath = coverAttachmentID.flatMap { coverID in
      attachments.first(where: { $0.id == coverID })?.repositoryPath.normalizedRelativePath()
    }
    let snapshot = RepositoryContentFingerprintSnapshot(
      title: title,
      date: date,
      slug: slug,
      tags: tags,
      categories: categories,
      importedFrontMatter: importedFrontMatter,
      authors: authors,
      aliases: aliases,
      permalink: permalink,
      translationKey: translationKey,
      draft: draft,
      visibility: visibility,
      summary: summary,
      coverRepositoryPath: coverRepositoryPath,
      bodyMarkdown: bodyMarkdown,
      attachments:
        attachments
        .map(RepositoryAttachmentFingerprintSnapshot.init)
        .sorted { lhs, rhs in
          if lhs.repositoryPath == rhs.repositoryPath {
            return lhs.relativePublishPath < rhs.relativePublishPath
          }
          return lhs.repositoryPath < rhs.repositoryPath
        },
      status: status
    )
    guard let data = try? Self.fingerprintEncoder.encode(snapshot) else {
      assertionFailure("Failed to encode RepositoryContentFingerprintSnapshot")
      let fallback =
        "\(id.uuidString):\(title):\(date.timeIntervalSince1970):\(bodyMarkdown.utf8.count)"
      return SHA256.hash(data: Data(fallback.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
