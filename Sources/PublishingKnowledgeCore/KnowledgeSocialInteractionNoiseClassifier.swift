import Foundation

/// Identifies short social-platform chrome without treating ordinary prose as noise.
///
/// A line is removed only when its complete meaningful content is made up of
/// interaction metrics or multiple action labels. Sentences that merely mention
/// words such as “查看”, “回复”, or “互动数量” are preserved.
package struct KnowledgeSocialInteractionNoiseClassifier {
  private let markdownLinkExpression: NSRegularExpression?
  private let metricExpressions: [NSRegularExpression]
  private let actionExpression: NSRegularExpression?
  private let qualifierExpression: NSRegularExpression?
  private let separatorExpression: NSRegularExpression?
  private let exactActionExpression: NSRegularExpression?
  private let revealRepliesExpression: NSRegularExpression?
  private let replyPermissionExpression: NSRegularExpression?
  private let newPostsExpression: NSRegularExpression?
  private let standaloneInteractionCountExpression: NSRegularExpression?

  package init() {
    let number = "[0-9０-９]+(?:[.,，][0-9０-９]+)*(?:\\s*(?:万|千|百|亿|[kKmMwW]))?"
    let wrappedNumber = "(?:[（(]\\s*)?\(number)(?:\\s*[)）])?"
    let chineseLabels = "(?:查看|浏览|阅读|回复|评论|点赞|喜欢|收藏|转发|分享|互动)"
    let chineseUnit = "(?:\\s*(?:次|条|个|人次?))?"
    let englishLabels = "(?:views?|repl(?:y|ies)|responses?|comments?|likes?|reactions?|engagements?|shares?|reposts?|retweets?|bookmarks?|impressions?)"
    let englishActions = "(?:views?|repl(?:y|ies)|responses?|comments?|likes?|reactions?|engagements?|shares?|reposts?|retweets?|bookmarks?|more)"

    markdownLinkExpression = try? NSRegularExpression(
      pattern: "\\[([^\\]]+)\\]\\([^\\n)]*\\)",
      options: [.caseInsensitive]
    )
    metricExpressions = [
      "\(chineseLabels)(?:次数|数量|数|量)?\\s*[：:]?\\s*\(wrappedNumber)\(chineseUnit)",
      "\(wrappedNumber)\(chineseUnit)\\s*\(chineseLabels)(?:次数|数量|数|量)?",
      "\\b\(englishLabels)\\s*:?\\s*\(wrappedNumber)\\b",
      "\\b\(wrappedNumber)\\s*\(englishLabels)\\b",
      "(?:💬|↩|🔁|🔄|❤|♥|👍|⭐|🔖|👁|👀)\\s*\(wrappedNumber)",
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    actionExpression = try? NSRegularExpression(
      pattern: "(?:查看|回复|评论|点赞|喜欢|收藏|转发|分享|互动|更多)|\\b\(englishActions)\\b",
      options: [.caseInsensitive]
    )
    qualifierExpression = try? NSRegularExpression(
      pattern: "(?:和|与|及|全部|更多|所有|展开|显示|加载|数量|数据|情况|详情)|\\b(?:and|all|more|show|load|counts?|details?)\\b",
      options: [.caseInsensitive]
    )
    separatorExpression = try? NSRegularExpression(
      pattern: "[\\s·•|｜/、,，;；:：()（）\\[\\]{}<>《》「」『』—–_.!！?？+-]+",
      options: []
    )
    exactActionExpression = try? NSRegularExpression(
      pattern: "^(?:查看|回复|评论|点赞|收藏|转发|分享|互动(?:数量|数据|情况)?|更多|\(englishActions))$",
      options: [.caseInsensitive]
    )
    revealRepliesExpression = try? NSRegularExpression(
      pattern: "^(?:(?:查看|展开|显示|加载)(?:全部|更多|所有)?(?:\\s*\(number)\\s*条?)?(?:回复|评论|互动)(?:详情)?|(?:view|show|load)(?:\\s+(?:all|more))?(?:\\s+\(number))?\\s+(?:replies|comments|reactions))$",
      options: [.caseInsensitive]
    )
    replyPermissionExpression = try? NSRegularExpression(
      pattern: "^(?:谁可以回复(?:此|这)?(?:帖子|帖文|动态)?|仅限(?:你关注的人|关注者|被提及的人|帖子提及的人|指定用户|部分用户|好友|粉丝)可以?回复|可以回复(?:此|这)?(?:帖子|帖文|动态)?(?:的人|的用户)?|(?:任何人|所有人|每个人|大家|所有(?:用户|账号|帐户))(?:都|均)?(?:可以|可)回复|你可以回复|回复权限|(?:who|people|accounts?|everyone|you)\\s+(?:can|may)\\s+repl(?:y|ies)|only\\s+(?:people|accounts?|users?)\\s+(?:you\\s+)?(?:mention(?:ed)?|follow)\\s+can\\s+reply|who can reply|replies are (?:limited|restricted))$",
      options: [.caseInsensitive]
    )
    newPostsExpression = try? NSRegularExpression(
      pattern: "^(?:(?:查看|显示|加载|展开)?\\s*(?:\(wrappedNumber))?\\s*(?:条|个)?\\s*(?:新帖子|新帖文|新贴文|新推文|新动态|新内容)(?:\\s*\(wrappedNumber))?|(?:有|又有)\\s*(?:\(wrappedNumber))?\\s*(?:条|个)?\\s*(?:新帖子|新帖文|新贴文|新推文|新动态|新内容)|(?:view|show|see|load)?\\s*(?:\(wrappedNumber))?\\s*new\\s+(?:posts?|updates?)(?:\\s*\(wrappedNumber))?)$",
      options: [.caseInsensitive]
    )
    standaloneInteractionCountExpression = try? NSRegularExpression(
      pattern: "^\(wrappedNumber)$",
      options: [.caseInsensitive]
    )
  }

  package func isNoiseLine(_ line: String) -> Bool {
    var remaining = canonicalText(from: line)
    guard !remaining.isEmpty, remaining.count <= 180 else { return false }

    if hasFullMatch(exactActionExpression, in: remaining)
      || hasFullMatch(revealRepliesExpression, in: remaining)
      || hasFullMatch(replyPermissionExpression, in: remaining)
      || hasFullMatch(newPostsExpression, in: remaining) {
      return true
    }

    var metricCount = 0
    for expression in metricExpressions {
      let range = fullRange(of: remaining)
      let matches = expression.matches(in: remaining, range: range)
      metricCount += matches.count
      remaining = expression.stringByReplacingMatches(
        in: remaining,
        range: range,
        withTemplate: " "
      )
    }

    let actionCount: Int
    if let actionExpression {
      let range = fullRange(of: remaining)
      actionCount = actionExpression.numberOfMatches(in: remaining, range: range)
      remaining = actionExpression.stringByReplacingMatches(
        in: remaining,
        range: range,
        withTemplate: " "
      )
    } else {
      actionCount = 0
    }

    remaining = replacingMatches(of: qualifierExpression, in: remaining, with: " ")
    remaining = replacingMatches(of: separatorExpression, in: remaining, with: "")
    guard remaining.isEmpty else { return false }
    return metricCount > 0 || actionCount >= 2
  }

  /// A bare number is ambiguous, so callers should remove it only when nearby
  /// lines establish that it belongs to an interaction-control cluster.
  package func isStandaloneInteractionCount(_ line: String) -> Bool {
    let value = canonicalText(from: line)
    guard !value.isEmpty, value.count <= 32 else { return false }
    return hasFullMatch(standaloneInteractionCountExpression, in: value)
  }

  private func canonicalText(from line: String) -> String {
    let ignorableEdgeCharacters = CharacterSet.whitespacesAndNewlines.union(
      CharacterSet(charactersIn: "?？!！。.")
    )
    return replacingMatches(of: markdownLinkExpression, in: line, with: "$1")
      .replacingOccurrences(of: "\u{fe0f}", with: "")
      .trimmingCharacters(in: ignorableEdgeCharacters)
  }

  private func hasFullMatch(_ expression: NSRegularExpression?, in value: String) -> Bool {
    guard let expression else { return false }
    let range = fullRange(of: value)
    guard let match = expression.firstMatch(in: value, range: range) else { return false }
    return match.range == range
  }

  private func replacingMatches(
    of expression: NSRegularExpression?,
    in value: String,
    with template: String
  ) -> String {
    guard let expression else { return value }
    let range = fullRange(of: value)
    return expression.stringByReplacingMatches(in: value, range: range, withTemplate: template)
  }

  private func fullRange(of value: String) -> NSRange {
    NSRange(value.startIndex..<value.endIndex, in: value)
  }
}
