import Foundation

package enum KnowledgeContentExtractionHTMLAdapter {
  package static func extract(
    data: Data,
    sourceName: String
  ) throws -> KnowledgeContentExtraction {
    let sanitized = try KnowledgeWebContentSanitizer().sanitize(
      data: data,
      sourceName: sourceName
    )
    var warnings = ["网页正文已在本机净化；原始 HTML 保持不变。"]
    if sanitized.selectedMainContent {
      warnings.append("已优先提取页面的 article/main 正文区域。")
    }
    if sanitized.removedNoiseBlockCount > 0 {
      warnings.append("已移除 \(sanitized.removedNoiseBlockCount) 个导航、广告或交互噪声区块。")
    }
    return KnowledgeContentExtraction(
      kind: .webpage,
      title: sanitized.title ?? KnowledgeContentExtractionService.humanizedFilename(sourceName),
      authors: sanitized.authors,
      language: sanitized.language,
      summary: sanitized.summary,
      tags: [],
      sections: sanitized.sections,
      warnings: warnings
    )
  }
}
