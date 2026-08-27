import PublishingWorkbenchCore
import SwiftUI

enum RepositoryAccessibilityIdentifier {
  /// Produces a short, deterministic token without exposing repository paths in the AX tree.
  static func token(for value: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return "\(value.utf8.count)-\(String(hash, radix: 16))"
  }
}

extension RepositoryChangedFile {
  var accessibilityIdentifierToken: String {
    RepositoryAccessibilityIdentifier.token(for: path)
  }
}

/// Ephemeral selection for one workbench window.  The persisted repository
/// report remains the source of truth; this only names a file within it.
enum RepositoryChangedFileSource: String, Equatable {
  case local
  case remote

  var localizedDisplayName: String {
    switch self {
    case .local:
      return "本地"
    case .remote:
      return "远端"
    }
  }
}

struct RepositoryChangedFileSelection: Equatable, Identifiable {
  let source: RepositoryChangedFileSource
  let sourcePath: String?
  let destinationPath: String

  init(source: RepositoryChangedFileSource, file: RepositoryChangedFile) {
    self.source = source
    sourcePath = file.sourcePath
    destinationPath = file.destinationPath
  }

  var id: String {
    "\(source.rawValue):\(sourcePath ?? "")\u{001F}\(destinationPath)"
  }

  func matches(_ file: RepositoryChangedFile) -> Bool {
    sourcePath == file.sourcePath && destinationPath == file.destinationPath
  }
}

enum RepositoryChangedFileSelectionPresentation {
  static func selectedFile(
    for selection: RepositoryChangedFileSelection?,
    localFiles: [RepositoryChangedFile],
    remoteFiles: [RepositoryChangedFile]
  ) -> RepositoryChangedFile? {
    guard let selection else { return nil }
    let files = selection.source == .local ? localFiles : remoteFiles
    return files.first(where: selection.matches)
  }

  static func reconciledSelection(
    _ selection: RepositoryChangedFileSelection?,
    localFiles: [RepositoryChangedFile],
    remoteFiles: [RepositoryChangedFile]
  ) -> RepositoryChangedFileSelection? {
    guard selectedFile(
      for: selection,
      localFiles: localFiles,
      remoteFiles: remoteFiles
    ) != nil else {
      return nil
    }
    return selection
  }
}

extension RepositoryWorkspaceView {
  var repositoryMetricGridColumns: [GridItem] {
    [GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 10)]
  }
}
