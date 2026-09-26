import Foundation
import PublishingGitCore

enum FirstRunRepositoryCloneError: LocalizedError {
  case invalidURL
  case destinationExists
  case destinationUnavailable
  case cloneFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return String(localized: "请输入有效的 GitHub 或 GitLab HTTPS 仓库地址。")
    case .destinationExists:
      return String(localized: "目标文件夹已存在，请更换保存位置或先连接已有仓库。")
    case .destinationUnavailable:
      return String(localized: "无法在所选位置创建仓库，请检查文件夹权限。")
    case .cloneFailed(let detail):
      return String(localized: "克隆未完成：") + detail
    }
  }
}

struct FirstRunRepositoryCloneSource: Equatable {
  let url: URL
  let folderName: String

  init?(text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmed),
      components.scheme?.lowercased() == "https",
      let host = components.host?.lowercased(),
      host == "github.com" || host == "gitlab.com",
      components.port == nil,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      !components.percentEncodedPath.lowercased().contains("%2f"),
      !components.percentEncodedPath.lowercased().contains("%5c")
    else { return nil }

    let pathParts = components.path.split(separator: "/").map(String.init)
    guard pathParts.count >= 2,
      host != "github.com" || pathParts.count == 2,
      pathParts.allSatisfy({ part in
        !part.isEmpty && part != "." && part != ".."
          && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
      }),
      let url = components.url
    else { return nil }

    let repositoryName = pathParts[pathParts.count - 1]
    let folderName =
      repositoryName.hasSuffix(".git")
      ? String(repositoryName.dropLast(4)) : repositoryName
    guard !folderName.isEmpty, folderName != ".", folderName != ".." else { return nil }
    self.url = url
    self.folderName = folderName
  }
}

@MainActor
enum FirstRunRepositoryCloneService {
  static func clone(_ source: FirstRunRepositoryCloneSource, in parentURL: URL) async throws -> URL
  {
    let parent = parentURL.standardizedFileURL
    let hasAccess = parent.startAccessingSecurityScopedResource()
    defer { if hasAccess { parent.stopAccessingSecurityScopedResource() } }
    var parentIsDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
      parentIsDirectory.boolValue
    else { throw FirstRunRepositoryCloneError.destinationUnavailable }

    let destination = parent.appendingPathComponent(source.folderName, isDirectory: true)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw FirstRunRepositoryCloneError.destinationExists
    }
    let temporary = parent.appendingPathComponent(
      ".repopress-clone-\(UUID().uuidString)", isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: temporary) }

    let result = await GitCommandRunner(timeout: 300, maximumOutputBytes: 32_768)
      .runAsync(["clone", "--", source.url.absoluteString, temporary.path], rootURL: parent)
    guard result.terminationStatus == 0, !result.didTimeOut else {
      let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
      throw FirstRunRepositoryCloneError.cloneFailed(
        detail.isEmpty ? String(localized: "请检查网络、仓库访问权限或地址后重试。") : String(detail.prefix(400))
      )
    }
    try Task.checkCancellation()
    guard FileManager.default.fileExists(atPath: temporary.appendingPathComponent(".git").path),
      !FileManager.default.fileExists(atPath: destination.path)
    else { throw FirstRunRepositoryCloneError.destinationUnavailable }
    do {
      try FileManager.default.moveItem(at: temporary, to: destination)
      return destination
    } catch {
      throw FirstRunRepositoryCloneError.destinationUnavailable
    }
  }
}
