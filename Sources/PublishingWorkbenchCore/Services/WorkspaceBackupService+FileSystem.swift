import CryptoKit
import Foundation

extension WorkspaceBackupService {
  func copyRegularFile(
    from sourceURL: URL,
    to destinationURL: URL,
    relativePath: String,
    component: WorkspaceBackupComponent
  ) throws -> WorkspaceBackupFileRecord {
    try validateRelativePath(relativePath)
    let sourceValues = try sourceURL.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    )
    guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
      throw WorkspaceBackupError.missingFile(relativePath)
    }
    let sourceSize = try fileSize(of: sourceURL, relativePath: relativePath)
    guard sourceSize <= limits.maximumSingleFileByteCount else {
      throw WorkspaceBackupError.fileTooLarge(
        path: relativePath,
        maximumByteCount: limits.maximumSingleFileByteCount
      )
    }
    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      throw WorkspaceBackupError.invalidPath(relativePath)
    }
    do {
      try fileManager.copyItem(at: sourceURL, to: destinationURL)
      let actualSize = try fileSize(of: destinationURL, relativePath: relativePath)
      let actualDigest = try sha256(of: destinationURL, relativePath: relativePath)
      guard actualSize == sourceSize else {
        throw WorkspaceBackupError.fileSizeMismatch(relativePath)
      }
      return WorkspaceBackupFileRecord(
        relativePath: relativePath,
        component: component,
        byteCount: actualSize,
        sha256: actualDigest
      )
    } catch {
      do {
        try fileManager.removeItem(at: destinationURL)
      } catch let cleanupError {
        throw WorkspaceBackupError.stagingFailed(
          "复制 \(relativePath) 失败：\(error.localizedDescription)；部分文件清理失败：\(cleanupError.localizedDescription)"
        )
      }
      throw error
    }
  }

  func fileSize(of url: URL, relativePath: String) throws -> Int64 {
    let attributes: [FileAttributeKey: Any]
    do {
      attributes = try fileManager.attributesOfItem(atPath: url.path)
    } catch {
      throw WorkspaceBackupError.missingFile(relativePath)
    }
    guard let number = attributes[.size] as? NSNumber else {
      throw WorkspaceBackupError.invalidPath(relativePath)
    }
    return number.int64Value
  }

  func sha256(of url: URL, relativePath: String) throws -> String {
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw WorkspaceBackupError.missingFile(relativePath)
    }
    defer { try? handle.close() }
    var hasher = SHA256()
    var totalByteCount: Int64 = 0
    while true {
      let data = handle.readData(ofLength: 1_048_576)
      if data.isEmpty { break }
      totalByteCount += Int64(data.count)
      guard totalByteCount <= limits.maximumSingleFileByteCount else {
        throw WorkspaceBackupError.fileTooLarge(
          path: relativePath,
          maximumByteCount: limits.maximumSingleFileByteCount
        )
      }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  func boundedData(
    at url: URL,
    maximumByteCount: Int,
    relativePath: String
  ) throws -> Data {
    let size = try fileSize(of: url, relativePath: relativePath)
    guard size <= Int64(maximumByteCount) else {
      throw WorkspaceBackupError.fileTooLarge(
        path: relativePath,
        maximumByteCount: Int64(maximumByteCount)
      )
    }
    do {
      return try Data(contentsOf: url, options: .mappedIfSafe)
    } catch {
      throw WorkspaceBackupError.missingFile(relativePath)
    }
  }

  func validateFileLimits(_ records: [WorkspaceBackupFileRecord]) throws -> Int64 {
    guard records.count <= limits.maximumFileCount else {
      throw WorkspaceBackupError.tooManyFiles(maximumCount: limits.maximumFileCount)
    }
    var totalByteCount: Int64 = 0
    for record in records {
      guard record.byteCount >= 0,
            record.byteCount <= limits.maximumSingleFileByteCount else {
        throw WorkspaceBackupError.fileTooLarge(
          path: record.relativePath,
          maximumByteCount: limits.maximumSingleFileByteCount
        )
      }
      let addition = totalByteCount.addingReportingOverflow(record.byteCount)
      guard !addition.overflow,
            addition.partialValue <= limits.maximumTotalByteCount else {
        throw WorkspaceBackupError.backupTooLarge(
          maximumByteCount: limits.maximumTotalByteCount
        )
      }
      totalByteCount = addition.partialValue
    }
    return totalByteCount
  }

  func encodeManifest(
    _ manifest: WorkspaceBackupManifest,
    to url: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(manifest).write(to: url, options: .atomic)
  }

  func encodedWorkbenchSnapshot(_ snapshot: WorkbenchSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(snapshot)
  }

  func normalizedPackageURL(_ url: URL) -> URL {
    guard url.pathExtension.lowercased() == "psworkspacebackup" else {
      return url.appendingPathExtension("psworkspacebackup")
    }
    return url
  }

  func safeFilename(_ raw: String, fallback: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
      .union(.controlCharacters)
    let sanitized = raw
      .components(separatedBy: forbidden)
      .joined(separator: "-")
      .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return String((sanitized.nilIfEmpty ?? fallback).prefix(160))
  }

  func installDirectory(
    _ stagedURL: URL,
    at destinationURL: URL
  ) throws {
    guard fileManager.fileExists(atPath: stagedURL.path) else { return }
    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try fileManager.moveItem(at: stagedURL, to: destinationURL)
  }

  func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws {
    guard !fileManager.fileExists(atPath: destinationURL.path) else {
      let displacedURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
        ".\(destinationURL.lastPathComponent).replaced-\(UUID().uuidString)",
        isDirectory: true
      )
      try fileManager.moveItem(at: destinationURL, to: displacedURL)
      do {
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        do {
          try fileManager.removeItem(at: displacedURL)
        } catch let cleanupError {
          throw WorkspaceBackupError.replacementCleanupFailed(
            path: displacedURL.path,
            reason: cleanupError.localizedDescription
          )
        }
      } catch {
        if !fileManager.fileExists(atPath: destinationURL.path) {
          do {
            try fileManager.moveItem(at: displacedURL, to: destinationURL)
          } catch let rollbackError {
            throw WorkspaceBackupError.replacementRollbackFailed(
              path: displacedURL.path,
              reason: "\(error.localizedDescription)；\(rollbackError.localizedDescription)"
            )
          }
        }
        throw error
      }
      return
    }
    try fileManager.moveItem(at: sourceURL, to: destinationURL)
  }
}
