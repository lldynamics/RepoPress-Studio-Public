import CryptoKit
import Foundation

struct DraftRepositoryDeletionEvidence: Hashable, Sendable {
  let contentSHA256: String
  let gitBlobSHA: String
}

extension LocalPublishPreviewService {
  func deletionEvidence(
    repositoryPath: String,
    profile: SiteProfile
  ) -> DraftRepositoryDeletionEvidence? {
    do {
      return try profile.withLocalRepositoryRootAccess { rootURL in
        guard let destinationURL = destinationURL(
          rootURL: rootURL,
          repositoryPath: repositoryPath
        ) else {
          throw LocalPublishPreviewError.unsafePath(repositoryPath)
        }
        let content = try readExistingMarkdownContent(at: destinationURL)
        let data = Data(content.utf8)
        let contentSHA256 = SHA256.hash(data: data)
          .map { String(format: "%02x", $0) }
          .joined()
        var blob = Data("blob \(data.count)\0".utf8)
        blob.append(data)
        let gitBlobSHA = Insecure.SHA1.hash(data: blob)
          .map { String(format: "%02x", $0) }
          .joined()
        return DraftRepositoryDeletionEvidence(
          contentSHA256: contentSHA256,
          gitBlobSHA: gitBlobSHA
        )
      }
    } catch {
      return nil
    }
  }

  func preview(package: PublishPackage, rootURL: URL) -> LocalPublishPreview {
    var diffs: [PublishFileDiff] = []
    var issues: [PreflightIssue] = []

    for file in package.files {
      guard let destinationURL = destinationURL(rootURL: rootURL, repositoryPath: file.repositoryPath) else {
        diffs.append(
          PublishFileDiff(path: file.repositoryPath, kind: file.kind, status: .unsafePath, byteSize: file.byteSize)
        )
        issues.append(
          .init(
            severity: .error,
            title: CoreL10n.text("发布路径不安全"),
            message: file.repositoryPath,
            field: "repositoryPath"
          )
        )
        continue
      }

      let baselineState: LocalPublishFileState
      do {
        baselineState = try localPublishFileState(at: destinationURL, fileManager: fileManager)
      } catch {
        diffs.append(
          PublishFileDiff(path: file.repositoryPath, kind: file.kind, status: .unsafePath, byteSize: file.byteSize)
        )
        issues.append(
          .init(
            severity: .error,
            title: CoreL10n.text("无法读取发布目标"),
            message: file.repositoryPath,
            field: "repositoryPath"
          )
        )
        continue
      }

      if file.operation == .delete {
        let exists = baselineState != .missing

        let existingContent: String
        if file.kind == .markdown, exists {
          do {
            existingContent = try readExistingMarkdownContent(at: destinationURL)
          } catch {
            diffs.append(
              PublishFileDiff(
                path: file.repositoryPath,
                kind: file.kind,
                status: .deleted,
                byteSize: file.byteSize,
                baselineState: nil
              )
            )
            issues.append(
              unreadableMarkdownIssue(
                repositoryPath: file.repositoryPath,
                error: error
              )
            )
            continue
          }
        } else {
          existingContent = ""
        }
        diffs.append(
          PublishFileDiff(
            path: file.repositoryPath,
            kind: file.kind,
            status: exists ? .deleted : .unchanged,
            lineDiff: exists && file.kind == .markdown
              ? unifiedDiff(old: existingContent, new: "")
              : nil,
            baselineState: baselineState
          )
        )
        continue
      }

      switch file.kind {
      case .markdown:
        let newContent = file.content ?? ""
        let exists = baselineState != .missing
        let existingContent: String
        if exists {
          do {
            existingContent = try readExistingMarkdownContent(at: destinationURL)
          } catch {
            diffs.append(
              PublishFileDiff(
                path: file.repositoryPath,
                kind: file.kind,
                status: .modified,
                byteSize: Int64(newContent.utf8.count),
                baselineState: nil
              )
            )
            issues.append(
              unreadableMarkdownIssue(
                repositoryPath: file.repositoryPath,
                error: error
              )
            )
            continue
          }
        } else {
          existingContent = ""
        }
        let status: PublishFileDiffStatus = exists
          ? (existingContent == newContent ? .unchanged : .modified)
          : .added
        diffs.append(
          PublishFileDiff(
            path: file.repositoryPath,
            kind: file.kind,
            status: status,
            lineDiff: status == .unchanged ? nil : unifiedDiff(old: existingContent, new: newContent),
            byteSize: Int64(newContent.utf8.count),
            baselineState: baselineState
          )
        )
      case .image, .video:
        guard let sourceFilePath = file.sourceFilePath else {
          diffs.append(
            PublishFileDiff(
              path: file.repositoryPath,
              kind: file.kind,
              status: .missingSource,
              byteSize: file.byteSize,
              baselineState: baselineState
            )
          )
          issues.append(.init(
            severity: .error,
            title: CoreL10n.format("%@源文件缺失", file.kind.displayName),
            message: file.repositoryPath,
            field: "attachments"
          ))
          continue
        }

        let sourceState: LocalPublishSourceFileState
        do {
          sourceState = try localPublishSourceFileState(
            at: URL(fileURLWithPath: sourceFilePath),
            repositoryPath: file.repositoryPath
          )
        } catch {
          let status: PublishFileDiffStatus
          let title: String
          if case LocalPublishPreviewError.missingSource = error {
            status = .missingSource
            title = CoreL10n.format("%@源文件缺失", file.kind.displayName)
          } else {
            status = .unsafePath
            title = CoreL10n.format("%@源文件不安全", file.kind.displayName)
          }
          diffs.append(
            PublishFileDiff(
              path: file.repositoryPath,
              kind: file.kind,
              status: status,
              byteSize: file.byteSize,
              baselineState: baselineState
            )
          )
          issues.append(.init(
            severity: .error,
            title: title,
            message: CoreL10n.format("%@：%@", file.repositoryPath, error.localizedDescription),
            field: "attachments"
          ))
          continue
        }

        let exists = baselineState != .missing
        let status: PublishFileDiffStatus
        if !exists {
          status = .added
        } else if baselineState == .fileDigest(sourceState.sha256) {
          status = .unchanged
        } else {
          status = .modified
        }
        diffs.append(
          PublishFileDiff(
            path: file.repositoryPath,
            kind: file.kind,
            status: status,
            byteSize: sourceState.byteSize,
            baselineState: baselineState,
            sourceState: sourceState
          )
        )
      }
    }

    return LocalPublishPreview(package: package, fileDiffs: diffs, issues: issues)
  }

  private func readExistingMarkdownContent(at url: URL) throws -> String {
    try BoundedFileReader.utf8String(
      at: url,
      maximumByteCount: WorkbenchContentFileReadLimits.textDocumentByteCount
    )
  }

  private func unreadableMarkdownIssue(
    repositoryPath: String,
    error: Error
  ) -> PreflightIssue {
    PreflightIssue(
      severity: .error,
      title: CoreL10n.text("无法读取现有 Markdown 文件"),
      message: CoreL10n.format("%@：%@", repositoryPath, error.localizedDescription),
      field: "repositoryPath"
    )
  }

  func missingRepositoryPreview(package: PublishPackage) -> LocalPublishPreview {
    LocalPublishPreview(
      package: package,
      fileDiffs: package.files.map {
        PublishFileDiff(path: $0.repositoryPath, kind: $0.kind, status: .unsafePath, byteSize: $0.byteSize)
      },
      issues: [
        .init(
          severity: .warning,
          title: CoreL10n.text("未选择本地仓库"),
          message: CoreL10n.text("选择仓库后才能生成真实文件 diff。"),
          field: "repository"
        )
      ]
    )
  }

  func unifiedDiff(old: String, new: String) -> String {
    let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var lines: [String] = ["--- repository", "+++ publish-package"]
    let maxCount = max(oldLines.count, newLines.count)
    let changedIndexes = Set((0..<maxCount).filter { index in
      let oldLine = index < oldLines.count ? oldLines[index] : nil
      let newLine = index < newLines.count ? newLines[index] : nil
      return oldLine != newLine
    })
    let contextRadius = 3
    let includedIndexes = Set(changedIndexes.flatMap { changedIndex in
      max(0, changedIndex - contextRadius)...min(maxCount - 1, changedIndex + contextRadius)
    })
    var skippedUnchangedLineCount = 0

    for index in 0..<maxCount {
      guard includedIndexes.contains(index) else {
        skippedUnchangedLineCount += 1
        continue
      }
      if skippedUnchangedLineCount > 0 {
        lines.append(" ... \(skippedUnchangedLineCount) unchanged line(s) ...")
        skippedUnchangedLineCount = 0
      }
      let oldLine = index < oldLines.count ? oldLines[index] : nil
      let newLine = index < newLines.count ? newLines[index] : nil
      if oldLine == newLine {
        if let oldLine {
          lines.append(" \(oldLine)")
        }
      } else {
        if let oldLine {
          lines.append("-\(oldLine)")
        }
        if let newLine {
          lines.append("+\(newLine)")
        }
      }
    }
    if skippedUnchangedLineCount > 0 {
      lines.append(" ... \(skippedUnchangedLineCount) unchanged line(s) ...")
    }

    return lines.joined(separator: "\n")
  }
}
