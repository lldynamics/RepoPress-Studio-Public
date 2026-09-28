import Darwin
import Foundation

extension ThemeShortcodeCatalogService {
  func scanDirectory(
    rootURL: URL,
    relativeDirectory: String,
    siteKind: SiteKind,
    source: ThemeShortcodeSource,
    priority: Int,
    remainingBytes: inout Int,
    diagnostics: inout [ThemeShortcodeCatalogDiagnostic]
  ) -> [Candidate] {
    guard isSafeRelativePath(relativeDirectory) else {
      diagnostics.append(
        .init(code: .unsafePath, message: "An unsafe shortcode directory was rejected."))
      return []
    }
    let directoryURL = rootURL.appendingPathComponent(relativeDirectory, isDirectory: true)
    guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
    guard isSafeDirectory(directoryURL, below: rootURL) else {
      diagnostics.append(
        .init(
          code: .unsafePath,
          message: "A shortcode directory is a symlink or escapes the repository.",
          repositoryPath: relativeDirectory))
      return []
    }

    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    guard
      let enumerator = fileManager.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      diagnostics.append(
        .init(
          code: .unreadableDirectory, message: "A shortcode directory cannot be read.",
          repositoryPath: relativeDirectory))
      return []
    }

    var result: [Candidate] = []
    var fileCount = 0
    while let url = enumerator.nextObject() as? URL {
      guard let relativePath = repositoryPath(of: url, below: rootURL) else {
        diagnostics.append(
          .init(code: .unsafePath, message: "A shortcode entry escaped the repository root."))
        continue
      }
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
        diagnostics.append(
          .init(
            code: .unreadableFile, message: "A shortcode entry cannot be inspected.",
            repositoryPath: relativePath))
        continue
      }
      if values.isSymbolicLink == true || isSymbolicLink(url) {
        enumerator.skipDescendants()
        diagnostics.append(
          .init(
            code: .unsafePath, message: "A symbolic link was excluded from the shortcode scan.",
            repositoryPath: relativePath))
        continue
      }
      if values.isDirectory == true {
        if depth(of: url, below: directoryURL) > Self.maximumDirectoryDepth {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values.isRegularFile == true, isTemplateFile(url, siteKind: siteKind) else { continue }
      fileCount += 1
      guard fileCount <= Self.maximumFilesPerDirectory else {
        diagnostics.append(
          .init(
            code: .scanLimitReached,
            message: "The shortcode directory contains too many template files.",
            repositoryPath: relativeDirectory))
        break
      }
      var byteBudget: Int? = remainingBytes
      guard
        let contents = readBoundedFile(url, remainingBytes: &byteBudget, diagnostics: &diagnostics)
      else { continue }
      remainingBytes = byteBudget ?? 0
      guard
        let definition = definition(
          for: url,
          contents: contents,
          siteKind: siteKind,
          source: source,
          relativeDirectory: relativeDirectory,
          repositoryPath: relativePath
        )
      else { continue }
      result.append(Candidate(definition: definition, priority: priority))
    }
    return result
  }

  func scanZolaComponents(
    rootURL: URL,
    relativeDirectory: String,
    priority: Int,
    remainingBytes: inout Int,
    diagnostics: inout [ThemeShortcodeCatalogDiagnostic]
  ) -> [Candidate] {
    guard isSafeRelativePath(relativeDirectory) else {
      diagnostics.append(
        .init(code: .unsafePath, message: "An unsafe component directory was rejected."))
      return []
    }
    let directoryURL = rootURL.appendingPathComponent(relativeDirectory, isDirectory: true)
    guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
    guard isSafeDirectory(directoryURL, below: rootURL) else {
      diagnostics.append(
        .init(
          code: .unsafePath,
          message: "A component directory is a symlink or escapes the repository.",
          repositoryPath: relativeDirectory))
      return []
    }

    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    guard
      let enumerator = fileManager.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      diagnostics.append(
        .init(
          code: .unreadableDirectory, message: "A component directory cannot be read.",
          repositoryPath: relativeDirectory))
      return []
    }

    var result: [Candidate] = []
    var fileCount = 0
    while let url = enumerator.nextObject() as? URL {
      guard let repositoryPath = repositoryPath(of: url, below: rootURL) else {
        diagnostics.append(
          .init(code: .unsafePath, message: "A component entry escaped the repository root."))
        continue
      }
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
        diagnostics.append(
          .init(
            code: .unreadableFile, message: "A component entry cannot be inspected.",
            repositoryPath: repositoryPath))
        continue
      }
      if values.isSymbolicLink == true || isSymbolicLink(url) {
        enumerator.skipDescendants()
        diagnostics.append(
          .init(
            code: .unsafePath, message: "A symbolic link was excluded from the component scan.",
            repositoryPath: repositoryPath))
        continue
      }
      if values.isDirectory == true {
        if depth(of: url, below: directoryURL) > Self.maximumDirectoryDepth {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values.isRegularFile == true, url.pathExtension.lowercased() == "html" else { continue }
      fileCount += 1
      guard fileCount <= Self.maximumFilesPerDirectory else {
        diagnostics.append(
          .init(
            code: .scanLimitReached,
            message: "The component directory contains too many template files.",
            repositoryPath: relativeDirectory))
        break
      }
      var byteBudget: Int? = remainingBytes
      guard
        let contents = readBoundedFile(url, remainingBytes: &byteBudget, diagnostics: &diagnostics)
      else { continue }
      remainingBytes = byteBudget ?? 0
      for component in teraComponents(in: contents) {
        result.append(
          Candidate(
            definition: ThemeShortcodeDefinition(
              name: component.name,
              parameters: component.parameters,
              insertionTemplate: teraComponentSnippet(
                name: component.name,
                parameters: component.parameters,
                inner: component.supportsInnerContent
              ),
              supportsInnerContent: component.supportsInnerContent,
              source: .teraComponent,
              repositoryPath: repositoryPath
            ),
            priority: priority
          ))
      }
    }
    return result
  }

  func readBoundedFile(
    _ url: URL,
    remainingBytes: inout Int?,
    diagnostics: inout [ThemeShortcodeCatalogDiagnostic]
  ) -> String? {
    guard !isSymbolicLink(url),
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true,
      let size = values.fileSize,
      size >= 0
    else {
      diagnostics.append(
        .init(
          code: .unsafePath, message: "A non-regular shortcode file was excluded.",
          repositoryPath: url.lastPathComponent))
      return nil
    }
    guard size <= Self.maximumFileBytes else {
      diagnostics.append(
        .init(
          code: .fileTooLarge, message: "A shortcode template exceeds the read limit.",
          repositoryPath: url.lastPathComponent))
      return nil
    }
    if let remaining = remainingBytes {
      guard remaining >= size else {
        diagnostics.append(
          .init(
            code: .scanLimitReached, message: "The shortcode catalog reached its total read limit.")
        )
        return nil
      }
      remainingBytes = remaining - size
    }
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
      let text = String(data: data, encoding: .utf8)
    else {
      diagnostics.append(
        .init(
          code: .unreadableFile, message: "A shortcode template cannot be decoded as UTF-8.",
          repositoryPath: url.lastPathComponent))
      return nil
    }
    return text
  }

  func isSafeDirectory(_ url: URL) -> Bool {
    var status = stat()
    guard !isSymbolicLink(url), Darwin.lstat(url.path, &status) == 0 else { return false }
    return (status.st_mode & S_IFMT) == S_IFDIR
  }

  func isSafeDirectory(_ url: URL, below rootURL: URL) -> Bool {
    let root = rootURL.standardizedFileURL
    let directory = url.standardizedFileURL
    let rootPath = root.path
    let directoryPath = directory.path
    guard directoryPath.hasPrefix(rootPath + "/"), isSafeDirectory(root) else { return false }
    var current = root
    for component in directoryPath.dropFirst(rootPath.count + 1).split(separator: "/") {
      current.appendPathComponent(String(component), isDirectory: true)
      guard isSafeDirectory(current) else { return false }
    }
    return true
  }

  func isSymbolicLink(_ url: URL) -> Bool {
    var status = stat()
    guard Darwin.lstat(url.path, &status) == 0 else { return false }
    return (status.st_mode & S_IFMT) == S_IFLNK
  }

  func repositoryPath(of url: URL, below root: URL) -> String? {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return nil }
    return String(path.dropFirst(rootPath.count + 1))
  }

  func depth(of url: URL, below root: URL) -> Int {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return .max }
    return path.dropFirst(rootPath.count + 1).split(separator: "/").count
  }

  func isTemplateFile(_ url: URL, siteKind: SiteKind) -> Bool {
    switch siteKind {
    case .hugo:
      return ["html", "htm", "xml"].contains(url.pathExtension.lowercased())
    case .zola:
      return ["html", "htm", "tera"].contains(url.pathExtension.lowercased())
    default:
      return false
    }
  }

  func isSafeRelativePath(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && !value.contains("\0")
      && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
      }
  }
}
