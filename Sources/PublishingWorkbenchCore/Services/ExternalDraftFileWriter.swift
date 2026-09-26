import CryptoKit
import Foundation

public enum ExternalDraftFileWriterError: LocalizedError, Equatable, Sendable {
  case inaccessibleRoot
  case invalidRelativePath(String)
  case sourceMissing(String)
  case sourceInaccessible(String)
  case sourceTooLarge(path: String, limit: Int)
  case conflict(expectedFingerprint: String, actualFingerprint: String)
  case writeFailed(path: String)

  public var errorDescription: String? {
    switch self {
    case .inaccessibleRoot:
      return CoreL10n.text("外部草稿目录无法访问。")
    case .invalidRelativePath(let path):
      return CoreL10n.format("外部草稿路径无效：%@", path)
    case .sourceMissing(let path):
      return CoreL10n.format("外部草稿文件不存在：%@", path)
    case .sourceInaccessible(let path):
      return CoreL10n.format("外部草稿文件无法安全访问：%@", path)
    case .sourceTooLarge(let path, let limit):
      return CoreL10n.format("外部草稿文件超过 %d 字节限制：%@", limit, path)
    case .conflict:
      return CoreL10n.text("外部草稿已被其他应用修改，请重新读取后再保存。")
    case .writeFailed(let path):
      return CoreL10n.format("无法写回外部草稿文件：%@", path)
    }
  }
}

/// Writes a previously scanned external Markdown draft only when its source
/// fingerprint still matches. The service never creates draft files or folders.
public struct ExternalDraftFileWriter: Sendable {
  public static let maximumFileSize = 16 * 1_024 * 1_024

  public init() {}

  /// Replaces an existing regular Markdown source through a same-directory
  /// staging file and returns the SHA-256 fingerprint of the written bytes.
  public func write(
    rootURL: URL,
    relativePath: String,
    expectedFingerprint: String,
    markdown: String
  ) throws -> String {
    let root = rootURL.standardizedFileURL
    let components = try validatedPathComponents(relativePath)
    try validateRoot(root)

    let destination = try destinationURL(
      root: root,
      components: components,
      relativePath: relativePath
    )
    let intendedData = Data(markdown.utf8)
    guard intendedData.count <= Self.maximumFileSize else {
      throw ExternalDraftFileWriterError.sourceTooLarge(
        path: relativePath,
        limit: Self.maximumFileSize
      )
    }
    let intendedFingerprint = fingerprint(of: intendedData)

    let currentData = try readVerifiedSource(
      at: destination,
      relativePath: relativePath
    )
    let currentFingerprint = fingerprint(of: currentData)
    guard currentFingerprint == expectedFingerprint else {
      throw ExternalDraftFileWriterError.conflict(
        expectedFingerprint: expectedFingerprint,
        actualFingerprint: currentFingerprint
      )
    }
    guard currentFingerprint != intendedFingerprint else {
      return intendedFingerprint
    }

    let existingPermissions = try sourcePermissions(
      at: destination,
      relativePath: relativePath
    )
    let directory = destination.deletingLastPathComponent()
    let staging = directory.appendingPathComponent(
      ".external-draft-write-\(UUID().uuidString.lowercased()).tmp",
      isDirectory: false
    )
    defer { try? fileManager.removeItem(at: staging) }

    do {
      try intendedData.write(to: staging, options: [])
      if let existingPermissions {
        try fileManager.setAttributes(
          [.posixPermissions: existingPermissions], ofItemAtPath: staging.path)
      }

      // Verify the exact existing entry immediately before publishing the
      // replacement. `replaceItemAt` requires a destination, so it cannot
      // turn a missing source into a newly created draft in normal operation.
      let immediatelyBeforeDestination = try destinationURL(
        root: root,
        components: components,
        relativePath: relativePath
      )
      let immediatelyBeforeWrite = try readVerifiedSource(
        at: immediatelyBeforeDestination,
        relativePath: relativePath
      )
      let immediatelyBeforeFingerprint = fingerprint(of: immediatelyBeforeWrite)
      guard immediatelyBeforeFingerprint == expectedFingerprint else {
        throw ExternalDraftFileWriterError.conflict(
          expectedFingerprint: expectedFingerprint,
          actualFingerprint: immediatelyBeforeFingerprint
        )
      }
      _ = try fileManager.replaceItemAt(
        immediatelyBeforeDestination,
        withItemAt: staging,
        backupItemName: nil,
        options: []
      )
    } catch let error as ExternalDraftFileWriterError {
      throw error
    } catch {
      throw ExternalDraftFileWriterError.writeFailed(path: relativePath)
    }
    return intendedFingerprint
  }

  private var fileManager: FileManager { .default }

  private func validatedPathComponents(_ relativePath: String) throws -> [Substring] {
    guard
      !relativePath.isEmpty,
      !relativePath.hasPrefix("/"),
      !relativePath.hasPrefix("\\\\"),
      !relativePath.hasPrefix("~")
    else {
      throw ExternalDraftFileWriterError.invalidRelativePath(relativePath)
    }
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard
      !components.isEmpty,
      components.allSatisfy({ component in
        !component.isEmpty && component != "." && component != ".." && !component.hasPrefix(".")
      }),
      let filename = components.last,
      isMarkdownFilename(String(filename))
    else {
      throw ExternalDraftFileWriterError.invalidRelativePath(relativePath)
    }
    return components
  }

  private func validateRoot(_ root: URL) throws {
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: root.path),
      attributes[.type] as? FileAttributeType == .typeDirectory,
      !isSymbolicLink(attributes),
      fileManager.isReadableFile(atPath: root.path)
    else {
      throw ExternalDraftFileWriterError.inaccessibleRoot
    }
  }

  private func destinationURL(
    root: URL,
    components: [Substring],
    relativePath: String
  ) throws -> URL {
    var current = root
    for (index, component) in components.enumerated() {
      current.appendPathComponent(String(component), isDirectory: index < components.count - 1)
      let isFinalComponent = index == components.count - 1
      guard let attributes = try? fileManager.attributesOfItem(atPath: current.path) else {
        throw ExternalDraftFileWriterError.sourceMissing(relativePath)
      }
      guard !isSymbolicLink(attributes) else {
        throw ExternalDraftFileWriterError.invalidRelativePath(relativePath)
      }
      if isFinalComponent {
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
          throw ExternalDraftFileWriterError.sourceInaccessible(relativePath)
        }
      } else {
        guard
          attributes[.type] as? FileAttributeType == .typeDirectory,
          fileManager.isReadableFile(atPath: current.path)
        else {
          throw ExternalDraftFileWriterError.sourceInaccessible(relativePath)
        }
      }
    }
    return current
  }

  private func readVerifiedSource(at url: URL, relativePath: String) throws -> Data {
    guard
      let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      attributes[.type] as? FileAttributeType == .typeRegular,
      !isSymbolicLink(attributes),
      fileManager.isReadableFile(atPath: url.path)
    else {
      if !fileManager.fileExists(atPath: url.path) {
        throw ExternalDraftFileWriterError.sourceMissing(relativePath)
      }
      throw ExternalDraftFileWriterError.sourceInaccessible(relativePath)
    }
    let declaredSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard declaredSize <= Self.maximumFileSize else {
      throw ExternalDraftFileWriterError.sourceTooLarge(
        path: relativePath, limit: Self.maximumFileSize)
    }
    do {
      let data = try Data(contentsOf: url, options: [.mappedIfSafe])
      guard data.count <= Self.maximumFileSize else {
        throw ExternalDraftFileWriterError.sourceTooLarge(
          path: relativePath, limit: Self.maximumFileSize)
      }
      return data
    } catch let error as ExternalDraftFileWriterError {
      throw error
    } catch {
      throw ExternalDraftFileWriterError.sourceInaccessible(relativePath)
    }
  }

  private func sourcePermissions(at url: URL, relativePath: String) throws -> NSNumber? {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
      throw ExternalDraftFileWriterError.sourceMissing(relativePath)
    }
    return attributes[.posixPermissions] as? NSNumber
  }

  private func isSymbolicLink(_ attributes: [FileAttributeKey: Any]) -> Bool {
    attributes[.type] as? FileAttributeType == .typeSymbolicLink
  }

  private func isMarkdownFilename(_ name: String) -> Bool {
    switch URL(fileURLWithPath: name).pathExtension.lowercased() {
    case "md", "markdown", "mdx", "txt":
      return true
    default:
      return false
    }
  }

  private func fingerprint(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
