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

extension RepositoryWorkspaceView {
  var repositoryMetricGridColumns: [GridItem] {
    [GridItem(.adaptive(minimum: 132, maximum: 220), spacing: 10)]
  }
}
