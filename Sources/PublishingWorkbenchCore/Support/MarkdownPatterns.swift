import Foundation

public enum MarkdownPatterns {
  /// 匹配 Markdown 图片的通用正则表达式。
  ///
  /// 该正则会匹配类似 `![alt](url "title")` 的格式：
  /// - Capture group 1: 图片的替代文本（alt text），不包含 `]`
  /// - Capture group 2: 图片的 URL 路径，不包含空格或 `)`
  public static let imagePattern = #"!\[([^\]]*)\]\(([^)\s]+)[^)]*\)"#

  /// 支持复杂匹配的 Markdown 图片正则。
  ///
  /// 该正则支持：
  /// - alt 文本中包含转义的 `]` 字符
  /// - URL 路径被 `< >` 包裹
  /// - URL 后可能带有用引号或括号包裹的 title
  public static let complexImagePattern = #"!\[((?:\\.|[^\]])*)\]\((?:<([^>]+)>|(.+?))(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?\)"#

  /// 用于动态构建带有特定图片路径正则的公共前缀模式，用于匹配 alt 文本
  public static let imagePrefixPattern = #"!\[((?:\\.|[^\]])*)\]\("#

  /// 用于动态构建带有特定图片路径正则的公共后缀模式，用于匹配 title 及闭合括号
  public static let imageSuffixPattern = #"(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?\)"#
}
