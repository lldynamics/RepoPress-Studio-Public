import Foundation

extension LocalPublishPreviewService {
  func destinationURL(rootURL: URL, repositoryPath: String) -> URL? {
    let relativePath = repositoryPath.normalizedRelativePath()
    guard !relativePath.isEmpty, !relativePath.contains(".."), !repositoryPath.hasPrefix("/") else {
      return nil
    }

    let canonicalRootURL = rootURL.standardizedFileURL
    guard !isSymbolicLink(canonicalRootURL) else {
      return nil
    }

    var destinationURL = canonicalRootURL
    for component in relativePath.split(separator: "/") {
      destinationURL.appendPathComponent(String(component), isDirectory: false)
      // Do not resolve symlinks and compare strings: a repository-owned link
      // could otherwise redirect a write or deletion outside its root.
      guard !isSymbolicLink(destinationURL) else {
        return nil
      }
    }

    let rootPath = canonicalRootURL.path
    guard destinationURL.path == rootPath || destinationURL.path.hasPrefix(rootPath + "/") else {
      return nil
    }
    return destinationURL
  }

  func safeDestinationURLForWrite(rootURL: URL, repositoryPath: String) throws -> URL {
    guard let destinationURL = destinationURL(rootURL: rootURL, repositoryPath: repositoryPath) else {
      throw LocalPublishPreviewError.unsafePath(repositoryPath)
    }

    let rootURL = rootURL.standardizedFileURL
    let relativeComponents = repositoryPath.normalizedRelativePath().split(separator: "/").map(String.init)
    guard relativeComponents.count >= 2 else {
      return destinationURL
    }

    var parentURL = rootURL
    for component in relativeComponents.dropLast() {
      parentURL.appendPathComponent(component, isDirectory: true)
      guard !isSymbolicLink(parentURL) else {
        throw LocalPublishPreviewError.unsafePath(repositoryPath)
      }

      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
          throw LocalPublishPreviewError.unsafePath(repositoryPath)
        }
      } else {
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: false)
      }
    }

    guard !isSymbolicLink(destinationURL) else {
      throw LocalPublishPreviewError.unsafePath(repositoryPath)
    }
    return destinationURL
  }

  func validatedDestinationURLForWrite(rootURL: URL, repositoryPath: String) throws -> URL {
    guard let destinationURL = destinationURL(rootURL: rootURL, repositoryPath: repositoryPath) else {
      throw LocalPublishPreviewError.unsafePath(repositoryPath)
    }

    let rootURL = rootURL.standardizedFileURL
    let relativeComponents = repositoryPath.normalizedRelativePath().split(separator: "/").map(String.init)
    var parentURL = rootURL
    for component in relativeComponents.dropLast() {
      parentURL.appendPathComponent(component, isDirectory: true)
      guard !isSymbolicLink(parentURL) else {
        throw LocalPublishPreviewError.unsafePath(repositoryPath)
      }
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: parentURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
        throw LocalPublishPreviewError.unsafePath(repositoryPath)
      }
    }

    var destinationIsDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: destinationURL.path, isDirectory: &destinationIsDirectory),
       destinationIsDirectory.boolValue {
      throw LocalPublishPreviewError.unsafePath(repositoryPath)
    }
    return destinationURL
  }

}
