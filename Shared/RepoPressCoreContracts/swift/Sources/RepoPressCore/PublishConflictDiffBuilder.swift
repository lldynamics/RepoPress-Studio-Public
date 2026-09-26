import Foundation

public struct PublishConflictDiffLine: Codable, Identifiable, Hashable, Sendable {
  public enum Kind: String, Codable, Hashable, Sendable {
    case same
    case remote
    case local
  }

  public var id: Int
  public var kind: Kind
  public var text: String

  public init(id: Int, kind: Kind, text: String) {
    self.id = id
    self.kind = kind
    self.text = text
  }

  public var marker: String {
    switch kind {
    case .same:
      return " "
    case .remote:
      return "-"
    case .local:
      return "+"
    }
  }
}

public struct PublishConflictDiffBuilder: Sendable {
  public init() {}

  public func diff(remote: String, local: String) -> [PublishConflictDiffLine] {
    let remoteLines = remote.components(separatedBy: .newlines)
    let localLines = local.components(separatedBy: .newlines)

    guard remoteLines.count * localLines.count <= 250_000 else {
      return coarseDiff(remoteLines: remoteLines, localLines: localLines)
    }

    var table = Array(
      repeating: Array(repeating: 0, count: localLines.count + 1),
      count: remoteLines.count + 1
    )

    if !remoteLines.isEmpty, !localLines.isEmpty {
      for remoteIndex in stride(from: remoteLines.count - 1, through: 0, by: -1) {
        for localIndex in stride(from: localLines.count - 1, through: 0, by: -1) {
          if remoteLines[remoteIndex] == localLines[localIndex] {
            table[remoteIndex][localIndex] = table[remoteIndex + 1][localIndex + 1] + 1
          } else {
            table[remoteIndex][localIndex] = max(
              table[remoteIndex + 1][localIndex],
              table[remoteIndex][localIndex + 1]
            )
          }
        }
      }
    }

    var result: [PublishConflictDiffLine] = []
    var remoteIndex = 0
    var localIndex = 0

    while remoteIndex < remoteLines.count, localIndex < localLines.count {
      if remoteLines[remoteIndex] == localLines[localIndex] {
        append(.same, remoteLines[remoteIndex], to: &result)
        remoteIndex += 1
        localIndex += 1
      } else if table[remoteIndex + 1][localIndex] >= table[remoteIndex][localIndex + 1] {
        append(.remote, remoteLines[remoteIndex], to: &result)
        remoteIndex += 1
      } else {
        append(.local, localLines[localIndex], to: &result)
        localIndex += 1
      }
    }

    while remoteIndex < remoteLines.count {
      append(.remote, remoteLines[remoteIndex], to: &result)
      remoteIndex += 1
    }

    while localIndex < localLines.count {
      append(.local, localLines[localIndex], to: &result)
      localIndex += 1
    }

    return result
  }

  private func coarseDiff(
    remoteLines: [String],
    localLines: [String]
  ) -> [PublishConflictDiffLine] {
    var result: [PublishConflictDiffLine] = []
    for line in remoteLines {
      append(.remote, line, to: &result)
    }
    for line in localLines {
      append(.local, line, to: &result)
    }
    return result
  }

  private func append(
    _ kind: PublishConflictDiffLine.Kind,
    _ text: String,
    to result: inout [PublishConflictDiffLine]
  ) {
    result.append(PublishConflictDiffLine(id: result.count, kind: kind, text: text))
  }
}
