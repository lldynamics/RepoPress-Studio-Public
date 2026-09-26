import Foundation
import PublishingDomainContracts

public struct LocalSitePreviewPlan: Codable, Hashable, Sendable {
  public var siteKind: SiteKind
  public var rootPath: String
  public var executablePath: String
  public var arguments: [String]
  public var command: String
  public var previewURL: URL
  public var notes: [String]
  public var usesDynamicPort: Bool
  public var diagnostics: LocalSitePreviewDiagnostics
  public var executionIdentity: LocalSitePreviewExecutionIdentity?

  public var port: Int? {
    previewURL.port
  }

  public init(
    siteKind: SiteKind,
    rootPath: String,
    executablePath: String,
    arguments: [String],
    command: String,
    previewURL: URL,
    notes: [String],
    usesDynamicPort: Bool = false,
    diagnostics: LocalSitePreviewDiagnostics? = nil,
    executionIdentity: LocalSitePreviewExecutionIdentity? = nil
  ) {
    self.siteKind = siteKind
    self.rootPath = rootPath
    self.executablePath = executablePath
    self.arguments = arguments
    self.command = command
    self.previewURL = previewURL
    self.notes = notes
    self.usesDynamicPort = usesDynamicPort
    self.diagnostics =
      diagnostics
      ?? LocalSitePreviewDiagnostics(
        siteKind: siteKind,
        rootPath: rootPath
      )
    self.executionIdentity = executionIdentity
  }

  private enum CodingKeys: String, CodingKey {
    case siteKind
    case rootPath
    case executablePath
    case arguments
    case command
    case previewURL
    case notes
    case usesDynamicPort
    case diagnostics
    case executionIdentity
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    siteKind = try container.decode(SiteKind.self, forKey: .siteKind)
    rootPath = try container.decode(String.self, forKey: .rootPath)
    executablePath = try container.decode(String.self, forKey: .executablePath)
    arguments = try container.decode([String].self, forKey: .arguments)
    command = try container.decode(String.self, forKey: .command)
    previewURL = try container.decode(URL.self, forKey: .previewURL)
    notes = try container.decode([String].self, forKey: .notes)
    usesDynamicPort = try container.decodeIfPresent(Bool.self, forKey: .usesDynamicPort) ?? false
    diagnostics =
      try container.decodeIfPresent(LocalSitePreviewDiagnostics.self, forKey: .diagnostics)
      ?? LocalSitePreviewDiagnostics(siteKind: siteKind, rootPath: rootPath)
    executionIdentity = try container.decodeIfPresent(
      LocalSitePreviewExecutionIdentity.self,
      forKey: .executionIdentity
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(siteKind, forKey: .siteKind)
    try container.encode(rootPath, forKey: .rootPath)
    try container.encode(executablePath, forKey: .executablePath)
    try container.encode(arguments, forKey: .arguments)
    try container.encode(command, forKey: .command)
    try container.encode(previewURL, forKey: .previewURL)
    try container.encode(notes, forKey: .notes)
    try container.encode(usesDynamicPort, forKey: .usesDynamicPort)
    try container.encode(diagnostics, forKey: .diagnostics)
    try container.encodeIfPresent(executionIdentity, forKey: .executionIdentity)
  }
}
