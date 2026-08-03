import Foundation

/// Paths owned by a data root. Every component declared by the manifest must
/// already exist; missing entries are treated as possible data loss instead of
/// being silently recreated while an existing root is opened.
public enum WorkbenchDataRootComponent: String, Codable, CaseIterable, Hashable, Sendable {
  case workbench
  case knowledgeLibrary
  case rssReader
  case managedAttachments
}

public struct WorkbenchDataRootManifest: Codable, Equatable, Hashable, Sendable {
  public static let currentFormatVersion = 1

  public var dataID: UUID
  public var formatVersion: Int
  public var createdAt: Date
  public var lastOpenedAppVersion: String
  public var components: [WorkbenchDataRootComponent]

  public init(
    dataID: UUID = UUID(),
    formatVersion: Int = WorkbenchDataRootManifest.currentFormatVersion,
    createdAt: Date = Date(),
    lastOpenedAppVersion: String,
    components: [WorkbenchDataRootComponent] = []
  ) {
    self.dataID = dataID
    self.formatVersion = formatVersion
    self.createdAt = createdAt
    self.lastOpenedAppVersion = lastOpenedAppVersion
    self.components = Array(Set(components)).sorted { $0.rawValue < $1.rawValue }
  }
}

public struct WorkbenchDataRootLayout: Equatable, Hashable, Sendable {
  public static let manifestFilename = "repopress-data-root.json"

  public let rootURL: URL

  public init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
  }

  public var manifestURL: URL {
    rootURL.appendingPathComponent(Self.manifestFilename, isDirectory: false)
  }

  public var workbenchFileURL: URL {
    rootURL.appendingPathComponent("workbench.json", isDirectory: false)
  }

  public var knowledgeLibraryURL: URL {
    rootURL.appendingPathComponent("KnowledgeLibrary", isDirectory: true)
  }

  public var knowledgeDatabaseURL: URL {
    knowledgeLibraryURL.appendingPathComponent("library.sqlite", isDirectory: false)
  }

  public var rssReaderURL: URL {
    rootURL.appendingPathComponent("RSSReader", isDirectory: true)
  }

  public var rssReaderDatabaseURL: URL {
    rssReaderURL.appendingPathComponent("reader.sqlite", isDirectory: false)
  }

  public var managedAttachmentsURL: URL {
    rootURL.appendingPathComponent("ManagedAttachments", isDirectory: true)
  }

  public func componentURL(for component: WorkbenchDataRootComponent) -> URL {
    switch component {
    case .workbench:
      return workbenchFileURL
    case .knowledgeLibrary:
      return knowledgeLibraryURL
    case .rssReader:
      return rssReaderURL
    case .managedAttachments:
      return managedAttachmentsURL
    }
  }
}

public enum WorkbenchDataRootIncompatibility: Equatable, Hashable, Sendable {
  case rootIsSymbolicLink
  case rootIsNotDirectory
  case rootCannotBeRead(String)
  case missingManifestForNonEmptyRoot
  case manifestIsNotRegularFile
  case malformedManifest(String)
  case unsupportedFormatVersion(found: Int, supported: Int)
  case emptyLastOpenedAppVersion
  case duplicateComponent(WorkbenchDataRootComponent)
  case declaredComponentMissing(WorkbenchDataRootComponent)
  case declaredComponentHasUnexpectedType(WorkbenchDataRootComponent)
  case undeclaredComponentPresent(WorkbenchDataRootComponent)
}

public enum WorkbenchDataRootProbeResult: Equatable, Hashable, Sendable {
  case new
  case existing(WorkbenchDataRootManifest)
  case incompatible(WorkbenchDataRootIncompatibility)
}

/// Metadata sidecars created by Finder and by macOS on non-Apple file systems.
///
/// ExFAT stores extended attributes in AppleDouble `._*` files. Those files
/// are not user payload and must not make an otherwise empty data root look
/// occupied or changed while it is being initialized.
enum WorkbenchDataRootFileSystemMetadata {
  static func isIgnorableEntry(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    return name == ".DS_Store" || name.hasPrefix("._")
  }
}

public struct WorkbenchDataRootCandidateProbe: Equatable, Hashable, Sendable {
  public var rootURL: URL
  public var result: WorkbenchDataRootProbeResult

  public init(rootURL: URL, result: WorkbenchDataRootProbeResult) {
    self.rootURL = rootURL.standardizedFileURL
    self.result = result
  }
}

public enum WorkbenchDataRootInitializationError: Error, Equatable, Sendable {
  case rootIsNotNew(WorkbenchDataRootProbeResult)
  case rootPreparationFailed(String)
  case rootChangedDuringInitialization
  case componentBootstrapFailed(String)
  case componentInstallFailed(String)
  case verificationFailed(WorkbenchDataRootProbeResult)
}

public struct WorkbenchDataRootManifestStore: Sendable {
  public init() {}

  public func read(from layout: WorkbenchDataRootLayout) throws -> WorkbenchDataRootManifest {
    let data = try Data(contentsOf: layout.manifestURL, options: [.mappedIfSafe])
    return try Self.makeDecoder().decode(WorkbenchDataRootManifest.self, from: data)
  }

  public func write(
    _ manifest: WorkbenchDataRootManifest,
    to layout: WorkbenchDataRootLayout
  ) throws {
    var data = try Self.makeEncoder().encode(manifest)
    data.append(0x0A)
    try data.write(to: layout.manifestURL, options: [.atomic])
  }

  /// Builds a complete, validated data root in a missing or empty folder.
  public func initializeNewRoot(
    at rootURL: URL,
    appVersion: String,
    dataID: UUID = UUID(),
    createdAt: Date = Date()
  ) throws -> WorkbenchDataRootManifest {
    try WorkbenchDataRootInitializer().initializeNewRoot(
      at: rootURL,
      appVersion: appVersion,
      dataID: dataID,
      createdAt: createdAt
    )
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

/// Performs a read-only classification of one or more candidate data roots.
///
/// Candidate results preserve caller order. This type intentionally does not
/// choose between two existing roots and never consults modification dates.
public struct WorkbenchDataRootInspector: Sendable {
  public init() {}

  public func probe(at rootURL: URL) -> WorkbenchDataRootProbeResult {
    let fileManager = FileManager.default
    let layout = WorkbenchDataRootLayout(rootURL: rootURL)

    if isSymbolicLink(at: layout.rootURL, fileManager: fileManager) {
      return .incompatible(.rootIsSymbolicLink)
    }

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: layout.rootURL.path, isDirectory: &isDirectory) else {
      return .new
    }
    guard isDirectory.boolValue else {
      return .incompatible(.rootIsNotDirectory)
    }

    let rootContents: [URL]
    do {
      rootContents = try fileManager.contentsOfDirectory(
        at: layout.rootURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
        options: []
      )
    } catch {
      return .incompatible(.rootCannotBeRead(error.localizedDescription))
    }

    guard fileManager.fileExists(atPath: layout.manifestURL.path) else {
      let meaningfulContents = rootContents.filter {
        !WorkbenchDataRootFileSystemMetadata.isIgnorableEntry($0)
      }
      return meaningfulContents.isEmpty
        ? .new
        : .incompatible(.missingManifestForNonEmptyRoot)
    }
    guard isRegularFile(at: layout.manifestURL, fileManager: fileManager) else {
      return .incompatible(.manifestIsNotRegularFile)
    }

    let manifest: WorkbenchDataRootManifest
    do {
      manifest = try WorkbenchDataRootManifestStore().read(from: layout)
    } catch {
      return .incompatible(.malformedManifest(error.localizedDescription))
    }

    return classify(manifest, layout: layout, fileManager: fileManager)
  }

  public func probeCandidates(at rootURLs: [URL]) -> [WorkbenchDataRootCandidateProbe] {
    rootURLs.map {
      WorkbenchDataRootCandidateProbe(rootURL: $0, result: probe(at: $0))
    }
  }

  private func classify(
    _ manifest: WorkbenchDataRootManifest,
    layout: WorkbenchDataRootLayout,
    fileManager: FileManager
  ) -> WorkbenchDataRootProbeResult {
    guard manifest.formatVersion == WorkbenchDataRootManifest.currentFormatVersion else {
      return .incompatible(
        .unsupportedFormatVersion(
          found: manifest.formatVersion,
          supported: WorkbenchDataRootManifest.currentFormatVersion
        )
      )
    }
    guard !manifest.lastOpenedAppVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .incompatible(.emptyLastOpenedAppVersion)
    }

    var observedComponents = Set<WorkbenchDataRootComponent>()
    for component in manifest.components {
      guard observedComponents.insert(component).inserted else {
        return .incompatible(.duplicateComponent(component))
      }
    }

    if let incompatibility = componentIncompatibility(
      declaredComponents: observedComponents,
      layout: layout,
      fileManager: fileManager
    ) {
      return .incompatible(incompatibility)
    }
    return .existing(manifest)
  }

  private func componentIncompatibility(
    declaredComponents: Set<WorkbenchDataRootComponent>,
    layout: WorkbenchDataRootLayout,
    fileManager: FileManager
  ) -> WorkbenchDataRootIncompatibility? {
    for component in WorkbenchDataRootComponent.allCases {
      let isDeclared = declaredComponents.contains(component)
      let presence = componentPresence(component, layout: layout, fileManager: fileManager)
      switch (isDeclared, presence) {
      case (true, .missing):
        return .declaredComponentMissing(component)
      case (true, .unexpectedType):
        return .declaredComponentHasUnexpectedType(component)
      case (false, .present), (false, .unexpectedType):
        return .undeclaredComponentPresent(component)
      case (true, .present), (false, .missing):
        break
      }
    }
    return nil
  }

  private enum ComponentPresence {
    case missing
    case present
    case unexpectedType
  }

  private func componentPresence(
    _ component: WorkbenchDataRootComponent,
    layout: WorkbenchDataRootLayout,
    fileManager: FileManager
  ) -> ComponentPresence {
    let componentURL = layout.componentURL(for: component)
    let componentExists = itemExists(at: componentURL, fileManager: fileManager)
    guard componentExists else { return .missing }

    switch component {
    case .workbench:
      return isRegularFile(at: componentURL, fileManager: fileManager) ? .present : .unexpectedType
    case .managedAttachments:
      return isDirectory(at: componentURL, fileManager: fileManager) ? .present : .unexpectedType
    case .knowledgeLibrary:
      guard isDirectory(at: componentURL, fileManager: fileManager) else {
        return .unexpectedType
      }
      guard itemExists(at: layout.knowledgeDatabaseURL, fileManager: fileManager) else {
        return .missing
      }
      return isRegularFile(at: layout.knowledgeDatabaseURL, fileManager: fileManager)
        ? .present
        : .unexpectedType
    case .rssReader:
      guard isDirectory(at: componentURL, fileManager: fileManager) else {
        return .unexpectedType
      }
      guard itemExists(at: layout.rssReaderDatabaseURL, fileManager: fileManager) else {
        return .missing
      }
      return isRegularFile(at: layout.rssReaderDatabaseURL, fileManager: fileManager)
        ? .present
        : .unexpectedType
    }
  }

  private func itemExists(at url: URL, fileManager: FileManager) -> Bool {
    if fileManager.fileExists(atPath: url.path) {
      return true
    }
    return (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

  private func isSymbolicLink(at url: URL, fileManager: FileManager) -> Bool {
    if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
      return true
    }
    return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }

  private func isRegularFile(at url: URL, fileManager: FileManager) -> Bool {
    guard !isSymbolicLink(at: url, fileManager: fileManager) else { return false }
    return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
  }

  private func isDirectory(at url: URL, fileManager: FileManager) -> Bool {
    guard !isSymbolicLink(at: url, fileManager: fileManager) else { return false }
    return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }
}
