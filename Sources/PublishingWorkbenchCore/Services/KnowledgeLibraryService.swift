import Foundation

enum KnowledgeImportInstalledArtifact {
  case created(destinationURL: URL)
  case replaced(destinationURL: URL, backupURL: URL)
}

public final class KnowledgeLibraryService: @unchecked Sendable {
  public static let parserVersion = 7

  public static func defaultRootURL(fileManager: FileManager = .default) -> URL {
    let supportURL =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return
      supportURL
      .appendingPathComponent("PersonalSitePublisherMac", isDirectory: true)
      .appendingPathComponent("KnowledgeLibrary", isDirectory: true)
  }

  public static func applyPendingRestoreIfNeeded(
    rootURL: URL? = nil,
    fileManager: FileManager = .default
  ) -> KnowledgeLibraryRestoreStartupOutcome {
    let resolvedRootURL = rootURL ?? defaultRootURL(fileManager: fileManager)
    do {
      let result = try KnowledgeLibraryBackupService(
        rootURL: resolvedRootURL,
        fileManager: fileManager
      ).applyPendingRestoreIfNeeded()
      return result.map(KnowledgeLibraryRestoreStartupOutcome.restored) ?? .none
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  public let rootURL: URL
  let databaseLock = NSLock()
  let storageMutationLock = NSLock()
  var cachedDatabase: KnowledgeDatabase?
  let semanticBackfillLock = NSLock()
  var backfilledSemanticModelIDs: Set<String> = []
  var inflightSemanticModelIDs: Set<String> = []
  var semanticBackfillTasks: [String: Task<Void, Never>] = [:]
  var semanticBackfillGeneration = 0
  let chunkingService: KnowledgeChunkingService
  let semanticEmbeddingService: KnowledgeSemanticEmbeddingService
  let searchPresentationService = KnowledgeSearchPresentationService()
  let searchDiversificationService = KnowledgeSearchDiversificationService()
  let revisionDifferenceService = KnowledgeRevisionDifferenceService()
  let webContentSanitizer = KnowledgeWebContentSanitizer()
  let contentExtractionService = KnowledgeContentExtractionService(
    htmlExtractor: { data, sourceName in
      try KnowledgeContentExtractionHTMLAdapter.extract(
        data: data,
        sourceName: sourceName
      )
    }
  )
  let imageOCRService = KnowledgeImageOCRService()
  let fileManager: FileManager
  let searchCancellationCheck: @Sendable () throws -> Void

  public convenience init(
    rootURL: URL? = nil,
    chunkingService: KnowledgeChunkingService = KnowledgeChunkingService(),
    fileManager: FileManager = .default
  ) {
    self.init(
      rootURL: rootURL,
      chunkingService: chunkingService,
      fileManager: fileManager,
      searchCancellationCheck: { try Task.checkCancellation() }
    )
  }

  init(
    rootURL: URL? = nil,
    chunkingService: KnowledgeChunkingService = KnowledgeChunkingService(),
    fileManager: FileManager = .default,
    semanticEmbeddingService: KnowledgeSemanticEmbeddingService =
      KnowledgeSemanticEmbeddingService(),
    searchCancellationCheck: @escaping @Sendable () throws -> Void
  ) {
    self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
    self.chunkingService = chunkingService
    self.semanticEmbeddingService = semanticEmbeddingService
    self.fileManager = fileManager
    self.searchCancellationCheck = searchCancellationCheck
  }

  func database() throws -> KnowledgeDatabase {
    databaseLock.lock()
    defer { databaseLock.unlock() }
    if let cachedDatabase { return cachedDatabase }
    let database = try KnowledgeDatabase(fileURL: rootURL.appendingPathComponent("library.sqlite"))
    cachedDatabase = database
    return database
  }
}
