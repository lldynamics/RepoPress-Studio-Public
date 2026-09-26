import CryptoKit
import Foundation

public final class KnowledgeNoteSnapshotPreferences: @unchecked Sendable {
  public static let standard = KnowledgeNoteSnapshotPreferences(userDefaults: .standard)
  private let userDefaults: UserDefaults

  public init(suiteName: String) {
    self.userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
  }

  private init(userDefaults: UserDefaults) { self.userDefaults = userDefaults }

  public func bool(forKey key: String) -> Bool { userDefaults.bool(forKey: key) }
  public func double(forKey key: String) -> Double { userDefaults.double(forKey: key) }
  public func string(forKey key: String) -> String? { userDefaults.string(forKey: key) }
  public func set(_ value: Any?, forKey key: String) { userDefaults.set(value, forKey: key) }
  public func removeObject(forKey key: String) { userDefaults.removeObject(forKey: key) }
}

public struct KnowledgeNoteSnapshotInfo: Identifiable, Sendable {
  public let url: URL
  public let createdAt: Date
  public var id: String { url.path }
}

public struct KnowledgeNoteSnapshotCreation: Sendable {
  public let url: URL
  public let contentSignature: String
}

/// The outcome of examining an existing automatic snapshot. `unknown` is
/// deliberately distinct from an invalid package: File Provider placeholders
/// and transient reads must not be mistaken for lost backup data.
public enum KnowledgeNoteSnapshotReadResult: Sendable {
  case package(RPNotePackage)
  case missing
  case invalid
  case unknown
}

/// Opt-in automatic snapshots are throttled so repeated keystroke saves do not
/// flood iCloud Drive. A local container write is recorded separately from the
/// system's eventual ubiquitous-item upload confirmation.
public actor KnowledgeNoteAutomaticSnapshotBackup {
  public static let shared = KnowledgeNoteAutomaticSnapshotBackup()
  public static let minimumInterval: TimeInterval = 24 * 60 * 60
  public static let retryInterval: TimeInterval = 15 * 60

  private let preferences: KnowledgeNoteSnapshotPreferences
  private let now: @Sendable () -> Date
  private let directoryProvider: @Sendable () throws -> URL
  private let snapshotReader: @Sendable (URL) -> KnowledgeNoteSnapshotReadResult
  private let uploadStatusReader: @Sendable (URL) -> KnowledgeNoteSnapshotUploadStatus

  public init(
    preferences: KnowledgeNoteSnapshotPreferences = .standard,
    now: @escaping @Sendable () -> Date = Date.init,
    directoryProvider: @escaping @Sendable () throws -> URL = {
      try KnowledgeNoteSnapshotBackupService.iCloudNotesBackupDirectory()
    },
    snapshotReader: @escaping @Sendable (URL) -> KnowledgeNoteSnapshotReadResult = {
      KnowledgeNoteSnapshotBackupService.snapshotReadResult(at: $0)
    },
    uploadStatusReader: @escaping @Sendable (URL) -> KnowledgeNoteSnapshotUploadStatus = {
      KnowledgeNoteSnapshotBackupService.uploadStatus(at: $0)
    }
  ) {
    self.preferences = preferences
    self.now = now
    self.directoryProvider = directoryProvider
    self.snapshotReader = snapshotReader
    self.uploadStatusReader = uploadStatusReader
  }

  @discardableResult
  public func createSnapshotIfDue(
    service: KnowledgeLibraryService,
    fileManager: FileManager = .default
  ) async throws -> URL? {
    guard preferences.bool(forKey: "knowledgeNoteICloudAutoBackupEnabled") else { return nil }
    let date = now()
    let previousAttempt = preferences.double(forKey: "knowledgeNoteICloudSnapshotLastAttemptAt")
    guard date.timeIntervalSince1970 - previousAttempt >= Self.retryInterval else { return nil }
    // Record every due inspection before provider reads. Unknown placeholders
    // and unavailable directories must be throttled just like a failed write.
    preferences.set(date.timeIntervalSince1970, forKey: "knowledgeNoteICloudSnapshotLastAttemptAt")

    let storedURL = preferences.string(forKey: "knowledgeNoteICloudSnapshotLastURL")
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
    let quickState = Self.quickSnapshotState(at: storedURL, fileManager: fileManager)
    let previousSuccess = preferences.double(forKey: "knowledgeNoteICloudSnapshotLastSuccessAt")
    let normalCheckIsDue =
      date.timeIntervalSince1970 - previousSuccess >= Self.minimumInterval
    var repairIsNeeded =
      quickState == .absent && previousSuccess > 0
    var preflightDirectory: URL?
    if !repairIsNeeded, !normalCheckIsDue, let storedURL {
      if quickState == .requiresVerification {
        switch snapshotReader(storedURL) {
        case .missing, .invalid:
          repairIsNeeded = true
        case .package, .unknown:
          return nil
        }
      }
      // This lightweight current-target check allows a renamed or changed
      // destination to be repaired after the retry interval without decoding
      // every attachment on each note save.
      if !repairIsNeeded {
        let directory: URL
        do {
          directory = try directoryProvider()
        } catch {
          return nil
        }
        preflightDirectory = directory
        repairIsNeeded = !KnowledgeNoteSnapshotBackupService.isSnapshot(
          storedURL, inside: directory)
      }
    }
    guard repairIsNeeded || normalCheckIsDue
    else { return nil }

    do {
      let directory = try preflightDirectory ?? directoryProvider()
      let notes = try await service.notesAsync().map(Self.portableNote)
      let signature = try KnowledgeNoteSnapshotBackupService.contentSignature(for: notes)

      switch snapshotReuseState(
        directory: directory,
        storedURL: storedURL,
        storedSignature: preferences.string(forKey: "knowledgeNoteICloudSnapshotContentHash"),
        currentSignature: signature
      ) {
      case .reusable:
        return nil
      case .unknown:
        return nil
      case .invalid:
        break
      }

      let url = try KnowledgeNoteSnapshotBackupService.createSnapshot(
        RPNotePackage(createdAt: date, notes: notes),
        in: directory,
        timestamp: date,
        fileManager: fileManager
      )
      preferences.set(
        date.timeIntervalSince1970, forKey: "knowledgeNoteICloudSnapshotLastSuccessAt")
      preferences.set(url.path, forKey: "knowledgeNoteICloudSnapshotLastURL")
      preferences.set(
        KnowledgeNoteSnapshotUploadStatus.waitingForUpload.rawValue,
        forKey: "knowledgeNoteICloudSnapshotUploadStatus")
      preferences.set(signature, forKey: "knowledgeNoteICloudSnapshotContentHash")
      preferences.removeObject(forKey: "knowledgeNoteICloudSnapshotLastError")
      return url
    } catch {
      preferences.set(error.localizedDescription, forKey: "knowledgeNoteICloudSnapshotLastError")
      throw error
    }
  }

  private enum QuickSnapshotState: Equatable {
    case absent
    case present
    case requiresVerification
  }

  private enum SnapshotReuseState {
    case reusable
    case invalid
    case unknown
  }

  private static func quickSnapshotState(
    at url: URL?,
    fileManager: FileManager
  ) -> QuickSnapshotState {
    guard let url else { return .absent }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      return .requiresVerification
    }
    guard url.pathExtension == "rpnotes", isDirectory.boolValue else {
      return .requiresVerification
    }
    return .present
  }

  private func snapshotReuseState(
    directory: URL,
    storedURL: URL?,
    storedSignature: String?,
    currentSignature: String
  ) -> SnapshotReuseState {
    guard let storedURL, let storedSignature,
      KnowledgeNoteSnapshotBackupService.isSnapshot(storedURL, inside: directory)
    else {
      return .invalid
    }

    switch snapshotReader(storedURL) {
    case .package(let package):
      do {
        let packageSignature = try KnowledgeNoteSnapshotBackupService.contentSignature(
          for: package.notes)
        guard packageSignature == storedSignature
        else { return .invalid }
        guard uploadStatusReader(storedURL) == .uploaded else { return .unknown }
        return packageSignature == currentSignature ? .reusable : .invalid
      } catch {
        return .invalid
      }
    case .missing, .invalid:
      return .invalid
    case .unknown:
      return .unknown
    }
  }

  private static func portableNote(_ note: KnowledgeNote) -> RPNote {
    RPNote(
      id: note.id,
      title: note.title,
      tags: note.tags,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      isArchived: note.isArchived,
      sourceURL: note.sourceURL,
      markdown: note.markdown,
      attachments: note.attachments.map {
        RPNoteAttachment(
          id: $0.id,
          fileName: $0.fileName,
          mimeType: $0.mimeType ?? "application/octet-stream",
          data: $0.data
        )
      }
    )
  }
}

public enum KnowledgeNoteSnapshotUploadStatus: String, Sendable, Equatable {
  case uploaded
  case uploading
  case waitingForUpload
  case unavailable
}

/// Writes independently named note-package snapshots into a selected directory
/// or the configured app ubiquity container.
public enum KnowledgeNoteSnapshotBackupService {
  public static func createICloudSnapshot(
    _ package: RPNotePackage,
    timestamp: Date = Date(),
    fileManager: FileManager = .default
  ) throws -> KnowledgeNoteSnapshotCreation {
    let directory = try iCloudNotesBackupDirectory(fileManager: fileManager)
    let url = try createSnapshot(
      package, in: directory, timestamp: timestamp, fileManager: fileManager)
    return KnowledgeNoteSnapshotCreation(
      url: url,
      contentSignature: try contentSignature(for: package.notes)
    )
  }

  public static func contentSignature(for notes: [RPNote]) throws -> String {
    var hasher = SHA256()
    for sourceNote in notes.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
      var note = sourceNote
      note.updatedAt = note.createdAt
      hasher.update(data: try RPNoteCloudPayload.encode(note))
      hasher.update(data: Data([0xff]))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  public static func createSnapshot(
    _ package: RPNotePackage,
    in directoryURL: URL,
    timestamp: Date = Date(),
    fileManager: FileManager = .default
  ) throws -> URL {
    let wrapper = try RPNotesPackageCodec.encode(package)
    let expectedPackage = try RPNotesPackageCodec.decode(wrapper)
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw SnapshotError.destinationIsNotDirectory
    }

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let stamp = formatter.string(from: timestamp)
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: ".", with: "-")
    let destinationName = "RepoPress-Notes-\(stamp)-\(UUID().uuidString.lowercased()).rpnotes"
    let stagingName = ".repopress-note-snapshot-\(UUID().uuidString)"
    var destination: URL?
    var stagingDirectory: URL?
    var stagedPackage: URL?
    do {
      // Coordinate the package creation inside the iCloud Documents tree too;
      // FileWrapper's atomic write protects the staged package contents.
      let stageCoordinator = NSFileCoordinator(filePresenter: nil)
      var stageCoordinationError: NSError?
      var stageError: Error?
      stageCoordinator.coordinate(
        writingItemAt: directoryURL, options: .forMerging, error: &stageCoordinationError
      ) { coordinatedDirectory in
        do {
          let stageDirectory = coordinatedDirectory.appendingPathComponent(
            stagingName, isDirectory: true)
          let stageURL = stageDirectory.appendingPathComponent(
            "snapshot.rpnotes", isDirectory: true)
          try fileManager.createDirectory(at: stageDirectory, withIntermediateDirectories: false)
          try wrapper.write(to: stageURL, options: .atomic, originalContentsURL: nil)
          destination = coordinatedDirectory.appendingPathComponent(
            destinationName, isDirectory: true)
          stagingDirectory = stageDirectory
          stagedPackage = stageURL
        } catch {
          stageError = error
        }
      }
      if let stageCoordinationError { throw stageCoordinationError }
      if let stageError { throw stageError }
      guard let destination, let stagingDirectory, let stagedPackage else {
        throw SnapshotError.coordinationFailed
      }
      // Moving to a fresh UUID path preserves prior snapshots and fails if a
      // destination unexpectedly already exists; this service never replaces one.
      let coordinator = NSFileCoordinator(filePresenter: nil)
      var coordinationError: NSError?
      var moveError: Error?
      coordinator.coordinate(writingItemAt: destination, options: [], error: &coordinationError) {
        coordinatedURL in
        do {
          try fileManager.moveItem(at: stagedPackage, to: coordinatedURL)
        } catch {
          moveError = error
        }
      }
      if let coordinationError { throw coordinationError }
      if let moveError { throw moveError }
      try? fileManager.removeItem(at: stagingDirectory)
      do {
        let decoded = try readSnapshot(at: destination)
        guard decoded == expectedPackage else { throw SnapshotError.verificationFailed }
      } catch {
        let cleanupCoordinator = NSFileCoordinator(filePresenter: nil)
        var cleanupError: NSError?
        cleanupCoordinator.coordinate(
          writingItemAt: destination, options: .forDeleting, error: &cleanupError
        ) { coordinatedURL in
          try? fileManager.removeItem(at: coordinatedURL)
        }
        throw error
      }
      return destination
    } catch {
      if let stagingDirectory { try? fileManager.removeItem(at: stagingDirectory) }
      throw error
    }
  }

  public static func readSnapshot(at url: URL) throws -> RPNotePackage {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var result: Result<RPNotePackage, Error>?
    coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError)
    { coordinatedURL in
      result = Result {
        let wrapper = try FileWrapper(url: coordinatedURL, options: .immediate)
        return try RPNotesPackageCodec.decode(wrapper)
      }
    }
    if let coordinationError { throw coordinationError }
    guard let result else { throw SnapshotError.coordinationFailed }
    return try result.get()
  }

  /// Separates an integrity failure that is safe to replace from a provider
  /// failure that may merely mean the package has not been materialized yet.
  public static func snapshotReadResult(
    at url: URL,
    fileManager: FileManager = .default
  ) -> KnowledgeNoteSnapshotReadResult {
    let placeholder = isUbiquitousPlaceholder(at: url)
    do {
      let attributes = try fileManager.attributesOfItem(atPath: url.path)
      guard url.pathExtension == "rpnotes",
        attributes[.type] as? FileAttributeType == .typeDirectory
      else { return .invalid }
      guard !placeholder else { return .unknown }
      return .package(try readSnapshot(at: url))
    } catch is RPNotesPackageError {
      return placeholder ? .unknown : .invalid
    } catch {
      return isKnownMissingFileError(error) && !placeholder ? .missing : .unknown
    }
  }

  fileprivate static func isSnapshot(_ url: URL, inside directory: URL) -> Bool {
    guard url.pathExtension == "rpnotes" else { return false }
    return url.deletingLastPathComponent().standardizedFileURL.path
      == directory.standardizedFileURL.path
  }

  private static func isUbiquitousPlaceholder(at url: URL) -> Bool {
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [
        .isUbiquitousItemKey,
        .ubiquitousItemDownloadingStatusKey,
      ])
    } catch {
      return false
    }
    guard values.isUbiquitousItem == true else { return false }
    return values.ubiquitousItemDownloadingStatus != .current
  }

  private static func isKnownMissingFileError(_ error: Error) -> Bool {
    guard let error = error as? CocoaError else { return false }
    return error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
  }

  public static func snapshots(in directoryURL: URL, fileManager: FileManager = .default) throws
    -> [KnowledgeNoteSnapshotInfo]
  {
    let urls = try fileManager.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )
    return urls.compactMap { url in
      guard url.pathExtension == "rpnotes",
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      else { return nil }
      let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
      return KnowledgeNoteSnapshotInfo(
        url: url,
        createdAt: values?.creationDate ?? values?.contentModificationDate ?? .distantPast
      )
    }.sorted { $0.createdAt > $1.createdAt }
  }

  public static func uploadStatus(at url: URL) -> KnowledgeNoteSnapshotUploadStatus {
    guard let urls = packageURLs(at: url) else { return .unavailable }
    var anyUploading = false
    for item in urls {
      guard
        let values = try? item.resourceValues(forKeys: [
          .isUbiquitousItemKey,
          .ubiquitousItemIsUploadedKey,
          .ubiquitousItemIsUploadingKey,
        ]), values.isUbiquitousItem == true
      else { return .unavailable }
      if values.ubiquitousItemIsUploaded == true { continue }
      if values.ubiquitousItemIsUploading == true {
        anyUploading = true
      } else {
        return .waitingForUpload
      }
    }
    return anyUploading ? .uploading : .uploaded
  }

  static func packageURLs(at url: URL) -> [URL]? {
    packageURLs(at: url) { directoryURL, errorHandler in
      FileManager.default.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles],
        errorHandler: errorHandler
      )
    }
  }

  static func packageURLs(
    at url: URL,
    enumerateContents: (URL, @escaping (URL, Error) -> Bool) -> FileManager.DirectoryEnumerator?
  ) -> [URL]? {
    var urls = [url]
    var enumerationFailed = false
    guard
      let enumerator = enumerateContents(
        url,
        { _, _ in
          enumerationFailed = true
          return false
        }
      )
    else { return nil }
    while let child = enumerator.nextObject() as? URL { urls.append(child) }
    return enumerationFailed ? nil : urls
  }

  public static func iCloudNotesBackupDirectory(
    fileManager: FileManager = .default,
    containerIdentifier: String = "iCloud.com.chengjinfang.repopress"
  ) throws -> URL {
    guard let container = fileManager.url(forUbiquityContainerIdentifier: containerIdentifier)
    else {
      throw SnapshotError.iCloudContainerUnavailable
    }
    var directory: URL?
    var operationError: Error?
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    coordinator.coordinate(
      writingItemAt: container, options: .forMerging, error: &coordinationError
    ) { coordinatedContainer in
      do {
        let coordinatedDirectory =
          coordinatedContainer
          .appendingPathComponent("Documents/NotesBackups", isDirectory: true)
        try fileManager.createDirectory(at: coordinatedDirectory, withIntermediateDirectories: true)
        directory = coordinatedDirectory
      } catch {
        operationError = error
      }
    }
    if let coordinationError { throw coordinationError }
    if let operationError { throw operationError }
    guard let directory else { throw SnapshotError.coordinationFailed }
    return directory
  }

  public static func iCloudUploadStatus(at path: String) -> KnowledgeNoteSnapshotUploadStatus {
    uploadStatus(at: URL(fileURLWithPath: path, isDirectory: true))
  }

  public enum SnapshotError: LocalizedError {
    case destinationIsNotDirectory
    case iCloudContainerUnavailable
    case coordinationFailed
    case verificationFailed

    public var errorDescription: String? {
      switch self {
      case .destinationIsNotDirectory:
        return "所选快照位置不是文件夹。"
      case .iCloudContainerUnavailable:
        return "iCloud 容器不可用。请检查 iCloud 登录状态与应用配置。"
      case .coordinationFailed:
        return "无法协调访问这份笔记快照。"
      case .verificationFailed:
        return "快照写入后校验失败，未将其登记为备份。"
      }
    }
  }
}
