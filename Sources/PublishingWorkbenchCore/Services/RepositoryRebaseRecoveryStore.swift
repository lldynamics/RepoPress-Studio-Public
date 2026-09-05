import Foundation

enum RepositoryRebaseRecoveryStoreError: Error, LocalizedError, Sendable, Equatable {
  case invalidDirectory
  case invalidRecord
  case recordTooLarge

  var errorDescription: String? {
    switch self {
    case .invalidDirectory:
      "变基恢复记录目录不可用。"
    case .invalidRecord:
      "变基恢复记录已损坏或不是普通文件。"
    case .recordTooLarge:
      "变基恢复记录超过安全大小限制。"
    }
  }
}

/// Persists only the minimum non-secret evidence needed to reconnect a
/// RepoPress rebase conflict with its exact WIP stash after an app restart.
struct RepositoryRebaseRecoveryStore: Sendable {
  private static let maximumRecordByteCount = 64 * 1_024
  private let directoryURL: URL

  init(recoveryArchiveDirectoryURL: URL) {
    directoryURL = recoveryArchiveDirectoryURL
      .appendingPathComponent("RepositoryRebaseRecovery", isDirectory: true)
  }

  func load(profileID: UUID) throws -> RepositoryRebaseRecoveryContext? {
    let fileManager = FileManager.default
    let url = recordURL(profileID: profileID)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw RepositoryRebaseRecoveryStoreError.invalidRecord
    }
    let size = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
    guard size <= Self.maximumRecordByteCount else {
      throw RepositoryRebaseRecoveryStoreError.recordTooLarge
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count <= Self.maximumRecordByteCount else {
      throw RepositoryRebaseRecoveryStoreError.recordTooLarge
    }
    do {
      return try decoder().decode(RepositoryRebaseRecoveryContext.self, from: data)
    } catch {
      throw RepositoryRebaseRecoveryStoreError.invalidRecord
    }
  }

  func save(_ context: RepositoryRebaseRecoveryContext, profileID: UUID) throws {
    try prepareDirectory()
    let data = try encoder().encode(context)
    guard data.count <= Self.maximumRecordByteCount else {
      throw RepositoryRebaseRecoveryStoreError.recordTooLarge
    }
    try data.write(to: recordURL(profileID: profileID), options: [.atomic])
  }

  func remove(profileID: UUID) throws {
    let fileManager = FileManager.default
    let url = recordURL(profileID: profileID)
    guard fileManager.fileExists(atPath: url.path) else { return }
    try fileManager.removeItem(at: url)
  }

  private func prepareDirectory() throws {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw RepositoryRebaseRecoveryStoreError.invalidDirectory
      }
      let values = try directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else {
        throw RepositoryRebaseRecoveryStoreError.invalidDirectory
      }
      return
    }
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
  }

  private func recordURL(profileID: UUID) -> URL {
    directoryURL.appendingPathComponent(profileID.uuidString.lowercased() + ".json")
  }

  private func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  private func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
