
import CryptoKit
import Foundation

extension WorkbenchPersistence {
  public var retiredFeatureArchiveDirectoryURL: URL {
    fileURL
      .deletingLastPathComponent()
      .appendingPathComponent("RetiredFeatureArchives", isDirectory: true)
  }

  public var imageOptimizationDirectoryURL: URL {
    fileURL
      .deletingLastPathComponent()
      .appendingPathComponent("OptimizedImages", isDirectory: true)
  }

  /// Removes successful batch folders that are no longer referenced by any
  /// attachment. Non-batch files are deliberately left untouched.
  @discardableResult
  func pruneUnreferencedImageOptimizationBatches(
    referencedSourceFilePaths: [String]
  ) -> Int {
    let fileManager = FileManager.default
    let rootURL = imageOptimizationDirectoryURL.standardizedFileURL
    guard
      let children = try? fileManager.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
      )
    else {
      return 0
    }

    let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    let referencedBatchNames = Set(
      referencedSourceFilePaths.compactMap { path -> String? in
        let sourcePath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard sourcePath.hasPrefix(rootPrefix) else { return nil }
        let relativePath = String(sourcePath.dropFirst(rootPrefix.count))
        guard let firstComponent = relativePath.split(separator: "/").first else { return nil }
        let name = String(firstComponent)
        return name.hasPrefix(".image-batch-") ? name : nil
      })

    var removedCount = 0
    for child in children where child.lastPathComponent.hasPrefix(".image-batch-") {
      let standardizedChild = child.standardizedFileURL
      guard standardizedChild.deletingLastPathComponent() == rootURL,
        !referencedBatchNames.contains(standardizedChild.lastPathComponent)
      else {
        continue
      }
      do {
        try fileManager.removeItem(at: standardizedChild)
        removedCount += 1
      } catch {
        continue
      }
    }
    return removedCount
  }

  func retiredFeatureArchivesFromPersistedSnapshots() throws
    -> [WorkbenchRetiredFeatureArchive]
  {
    let sourceURLs = [fileURL, lastKnownGoodURL]
    var archivesByFileName: [String: WorkbenchRetiredFeatureArchive] = [:]

    for sourceURL in sourceURLs where FileManager.default.fileExists(atPath: sourceURL.path) {
      let sourceData = try Data(contentsOf: sourceURL)
      guard let archive = retiredFeatureArchive(from: sourceData) else { continue }
      archivesByFileName[archive.fileName] = archive
    }

    return archivesByFileName.values.sorted { $0.fileName < $1.fileName }
  }

  private func retiredFeatureArchive(from sourceData: Data) -> WorkbenchRetiredFeatureArchive? {
    guard var source = try? JSONSerialization.jsonObject(with: sourceData) as? [String: Any] else {
      return nil
    }

    let retiredKeys = [
      "contentPerformanceSnapshots",
      "externalVerificationEvidenceRecords",
      "scheduledPublishJobs",
    ]
    let retiredFields = Dictionary(
      uniqueKeysWithValues: retiredKeys.compactMap { key -> (String, Any)? in
        guard let value = source.removeValue(forKey: key), retiredFieldContainsData(value) else {
          return nil
        }
        return (key, value)
      })
    guard !retiredFields.isEmpty else { return nil }

    let sourceFormatVersion = source["formatVersion"] as? Int ?? 1
    let archiveObject: [String: Any] = [
      "archiveFormatVersion": 1,
      "sourceFormatVersion": sourceFormatVersion,
      "retiredFields": retiredFields,
    ]
    guard
      let archiveData = try? JSONSerialization.data(
        withJSONObject: archiveObject,
        options: [.prettyPrinted, .sortedKeys]
      )
    else {
      return nil
    }
    let digest = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
    return WorkbenchRetiredFeatureArchive(
      fileName: "workbench-v\(sourceFormatVersion)-\(digest).json",
      data: archiveData
    )
  }

  private func retiredFieldContainsData(_ value: Any) -> Bool {
    if let array = value as? [Any] {
      return !array.isEmpty
    }
    if let dictionary = value as? [String: Any] {
      return !dictionary.isEmpty
    }
    return !(value is NSNull)
  }

  func persistRetiredFeatureArchives(_ archives: [WorkbenchRetiredFeatureArchive]) throws {
    guard !archives.isEmpty else { return }
    try FileManager.default.createDirectory(
      at: retiredFeatureArchiveDirectoryURL,
      withIntermediateDirectories: true
    )

    for archive in archives {
      let archiveURL = retiredFeatureArchiveDirectoryURL.appendingPathComponent(archive.fileName)
      if FileManager.default.fileExists(atPath: archiveURL.path) {
        guard try Data(contentsOf: archiveURL) == archive.data else {
          throw WorkbenchPersistenceError.retiredFeatureArchiveConflict(archive.fileName)
        }
        continue
      }
      let temporaryURL = retiredFeatureArchiveDirectoryURL.appendingPathComponent(
        ".\(archive.fileName).\(UUID().uuidString).tmp"
      )
      do {
        try archive.data.write(to: temporaryURL, options: .atomic)
        do {
          try FileManager.default.moveItem(at: temporaryURL, to: archiveURL)
        } catch {
          if FileManager.default.fileExists(atPath: archiveURL.path),
            try Data(contentsOf: archiveURL) == archive.data
          {
            try? FileManager.default.removeItem(at: temporaryURL)
            continue
          }
          throw error
        }
      } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        throw error
      }
  }
}
}
