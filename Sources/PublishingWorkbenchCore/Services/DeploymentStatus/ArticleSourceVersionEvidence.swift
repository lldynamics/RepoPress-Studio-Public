import Foundation

/// An opt-in build contract: the generated page identifies the exact UTF-8
/// repository Markdown used by that build, including its front matter.
enum ArticleSourceVersionEvidence: Equatable {
  case verified(String)
  case missingExpectedDigest
  case missingMarker
  case invalidMarker
  case mismatch

  static let metaName = "repopress:source-digest"

  static func normalizedDigest(_ value: String) -> String? {
    guard value.utf8.count == 64,
      value.utf8.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      })
    else { return nil }
    return value.lowercased()
  }

  static func check(html: String, expectedDigest: String?) -> Self {
    guard let expectedDigest, let expected = normalizedDigest(expectedDigest) else {
      return .missingExpectedDigest
    }
    let markers = HTMLMetadataScanner.elements(named: "meta", in: html, withinHead: true)
      .filter { $0["name"]?.lowercased() == metaName }
    guard !markers.isEmpty else { return .missingMarker }
    // Duplicate markers are ambiguous even if one happens to match this release.
    guard markers.count == 1, let content = markers[0]["content"],
      let observed = normalizedDigest(content)
    else { return .invalidMarker }
    return observed == expected ? .verified(expected) : .mismatch
  }
}

extension DeploymentStatusService {
  func articleSourceVersionSignal(body: String, expectedDigest: String?, urlText: String)
    -> DeploymentStatusSignal
  {
    let evidence = ArticleSourceVersionEvidence.check(html: body, expectedDigest: expectedDigest)
    let level: DeploymentStatusLevel
    let message: String
    var verifiedDigest: String?
    switch evidence {
    case .verified(let digest):
      level = .success
      verifiedDigest = digest
      message = CoreL10n.text("页面版本标记与本次发布的文章源文件一致。")
    case .missingExpectedDigest:
      level = .unknown
      message = CoreL10n.text("此历史发布没有保存文章源文件摘要，正文版本尚未确认。")
    case .missingMarker:
      level = .unknown
      message = CoreL10n.text("页面未提供文章版本标记；可达性与标题检查不能确认正文已更新。")
    case .invalidMarker:
      level = .failed
      message = CoreL10n.text("页面的文章版本标记无效或重复；请检查站点构建配置。")
    case .mismatch:
      level = .failed
      message = CoreL10n.text("页面版本与本次发布不一致；请等待缓存更新或检查部署产物。")
    }
    return DeploymentStatusSignal(
      level: level, title: CoreL10n.text("文章正文版本"), message: message, urlText: urlText,
      verifiedSourceDocumentDigest: verifiedDigest)
  }
}
