import Foundation

extension DeploymentStatusService {

  func endpointSignal(
    urlText: String,
    provider: DeploymentProvider,
    token: String?,
    usesToken: Bool
  ) async -> DeploymentStatusSignal {
    guard let url = URL(string: urlText), url.scheme != nil, url.host != nil else {
      return DeploymentStatusSignal(level: .failed, title: "状态端点", message: "URL 无效：\(urlText)")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("PersonalSitePublisherMac/DeploymentStatus", forHTTPHeaderField: "User-Agent")
    if usesToken {
      guard CredentialedEndpointPolicy.isSecureRequestURL(url) else {
        return DeploymentStatusSignal(
          level: .failed,
          title: "状态端点",
          message: "使用 Bearer Token 的状态端点必须使用 HTTPS；本次未发送 Token。",
          urlText: nil
        )
      }
      guard let token = token?.trimmedForPublishing, !token.isEmpty else {
        return DeploymentStatusSignal(
          level: .unknown,
          title: "状态端点未检查",
          message: "该端点要求 Bearer Token，但当前未保存 Token；本次未发起请求。",
          urlText: urlText
        )
      }
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    do {
      let (data, response) = try await transport.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        return DeploymentStatusSignal(level: .unknown, title: "\(provider.displayName) 可达性", message: "端点没有返回 HTTP 状态。")
      }
      if let endpoint = decodedEndpointStatus(data: data) {
        let httpSucceeded = (200..<400).contains(httpResponse.statusCode)
        let level = endpoint.level == .unknown && !httpSucceeded ? .failed : endpoint.level
        let fallbackMessage = level == .failed && endpoint.level == .unknown
          ? "HTTP \(httpResponse.statusCode)"
          : "HTTP \(httpResponse.statusCode) · \(endpoint.rawStatus)"
        return DeploymentStatusSignal(
          level: level,
          title: endpoint.title?.nilIfEmpty ?? "\(provider.displayName) 状态",
          message: endpoint.message?.nilIfEmpty ?? fallbackMessage,
          urlText: endpoint.urlText?.nilIfEmpty ?? urlText
        )
      }
      return DeploymentStatusSignal(
        level: (200..<400).contains(httpResponse.statusCode) ? .success : .failed,
        title: "\(provider.displayName) 可达性",
        message: "HTTP \(httpResponse.statusCode)",
        urlText: urlText
      )
    } catch {
      return DeploymentStatusSignal(
        level: .failed,
        title: "\(provider.displayName) 可达性",
        message: error.localizedDescription,
        urlText: urlText
      )
    }
  }

  func articlePageSignals(
    siteURLText: String,
    profile: SiteProfile,
    releaseRecord: ReleaseRecord?
  ) async -> [DeploymentStatusSignal] {
    guard let releaseRecord,
          let markdownPath = releaseRecord.markdownPath?.trimmedForPublishing.nilIfEmpty,
          let articleURLText = articleURL(siteURLText: siteURLText, markdownPath: markdownPath, siteKind: profile.siteKind),
          let articleURL = URL(string: articleURLText) else {
      return []
    }

    var request = URLRequest(url: articleURL)
    request.httpMethod = "GET"
    request.setValue("PersonalSitePublisherMac/DeploymentArticleCheck", forHTTPHeaderField: "User-Agent")

    do {
      let (data, response) = try await transport.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else {
        return [DeploymentStatusSignal(
          level: .unknown,
          title: "发布页面内容",
          message: "文章页面没有返回 HTTP 状态。",
          urlText: articleURLText
        )]
      }
      guard (200..<400).contains(httpResponse.statusCode) else {
        return [DeploymentStatusSignal(
          level: .failed,
          title: "发布页面内容",
          message: "文章页面 HTTP \(httpResponse.statusCode)。",
          urlText: articleURLText
        )]
      }

      let body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
      let seoSignal = articlePageSEOSignal(body: body, expectedURLText: articleURLText)
      let socialSignal = articlePageSocialSignal(
        body: body,
        expectedTitle: releaseRecord.draftTitle,
        expectedSummary: releaseRecord.draftSummary,
        expectedImageAltText: releaseRecord.draftCoverAltText,
        expectedURLText: articleURLText
      )
      guard let expectedTitle = releaseRecord.draftTitle?.trimmedForPublishing.nilIfEmpty else {
        return [
          DeploymentStatusSignal(
            level: .success,
            title: "发布页面内容",
            message: "文章页面可访问。",
            urlText: articleURLText
          ),
          seoSignal,
        ] + [socialSignal].compactMap { $0 }
      }

      if body.localizedCaseInsensitiveContains(expectedTitle) {
        return [
          DeploymentStatusSignal(
            level: .success,
            title: "发布页面内容",
            message: "已在发布页面找到文章标题：\(expectedTitle)",
            urlText: articleURLText
          ),
          seoSignal,
        ] + [socialSignal].compactMap { $0 }
      }
      return [
        DeploymentStatusSignal(
          level: .failed,
          title: "发布页面内容",
          message: "文章页面可访问，但没有找到文章标题：\(expectedTitle)",
          urlText: articleURLText
        ),
        seoSignal,
      ] + [socialSignal].compactMap { $0 }
    } catch {
      return [DeploymentStatusSignal(
        level: .failed,
        title: "发布页面内容",
        message: "读取文章页面失败：\(error.localizedDescription)",
        urlText: articleURLText
      )]
    }
  }

  func articlePageSocialSignal(
    body: String,
    expectedTitle: String?,
    expectedSummary: String?,
    expectedImageAltText: String?,
    expectedURLText: String
  ) -> DeploymentStatusSignal? {
    let expectedTitle = expectedTitle?.trimmedForPublishing.nilIfEmpty
    let expectedSummary = expectedSummary?.trimmedForPublishing.nilIfEmpty
    let expectedImageAltText = expectedImageAltText?.trimmedForPublishing.nilIfEmpty
    guard expectedSummary != nil || expectedImageAltText != nil else {
      return nil
    }

    if let expectedTitle {
      let titleCandidates = [
        ("og:title", firstMetaContent(in: body, nameOrProperty: "og:title")),
        ("twitter:title", firstMetaContent(in: body, nameOrProperty: "twitter:title")),
      ].compactMap { name, value -> (String, String)? in
        guard let value = value?.nilIfEmpty else { return nil }
        return (name, value)
      }

      guard !titleCandidates.isEmpty else {
        return DeploymentStatusSignal(
          level: .failed,
          title: "发布页面社交元数据",
          message: "缺少 og:title 或 twitter:title，无法确认社交卡片标题。",
          urlText: expectedURLText
        )
      }

      guard titleCandidates.contains(where: { socialText($0.1, matches: expectedTitle) }) else {
        let first = titleCandidates[0]
        return DeploymentStatusSignal(
          level: .failed,
          title: "发布页面社交元数据",
          message: "\(first.0) 与发布记录标题不一致：\(first.1)",
          urlText: expectedURLText
        )
      }
    }

    if let expectedSummary {
      let descriptionCandidates = [
        ("meta description", firstMetaContent(in: body, nameOrProperty: "description")),
        ("og:description", firstMetaContent(in: body, nameOrProperty: "og:description")),
        ("twitter:description", firstMetaContent(in: body, nameOrProperty: "twitter:description")),
      ].compactMap { name, value -> (String, String)? in
        guard let value = value?.nilIfEmpty else { return nil }
        return (name, value)
      }

      guard !descriptionCandidates.isEmpty else {
        return DeploymentStatusSignal(
          level: .failed,
          title: "发布页面社交元数据",
          message: "缺少 meta description、og:description 或 twitter:description，无法确认社交分享摘要。",
          urlText: expectedURLText
        )
      }

      guard descriptionCandidates.contains(where: { socialText($0.1, matches: expectedSummary) }) else {
        let first = descriptionCandidates[0]
        return DeploymentStatusSignal(
          level: .failed,
          title: "发布页面社交元数据",
          message: "\(first.0) 与发布记录摘要不一致：\(first.1)",
          urlText: expectedURLText
        )
      }
    }

    if let expectedImageAltText {
      let imageCandidates = [
        ("og:image", firstMetaContent(in: body, nameOrProperty: "og:image")),
        ("twitter:image", firstMetaContent(in: body, nameOrProperty: "twitter:image")),
      ].compactMap { name, value -> (String, String)? in
        guard let value = value?.nilIfEmpty else { return nil }
        return (name, value)
      }

      guard !imageCandidates.isEmpty else {
        return DeploymentStatusSignal(
          level: .failed,
          title: "发布页面社交元数据",
          message: "缺少 og:image 或 twitter:image，无法确认社交图 URL。",
          urlText: expectedURLText
        )
      }

      let resolvedImageCandidates = imageCandidates.compactMap { name, value -> (String, String)? in
        guard let urlText = absoluteURLText(value, relativeTo: expectedURLText) else {
          return nil
        }
        return (name, urlText)
      }
      guard let socialImageURLText = resolvedImageCandidates.first else {
        return DeploymentStatusSignal(
          level: .failed,
          title: "发布页面社交元数据",
          message: "\(imageCandidates[0].0) 不是有效 URL：\(imageCandidates[0].1)",
          urlText: expectedURLText
        )
      }

      let altCandidates = [
        ("og:image:alt", firstMetaContent(in: body, nameOrProperty: "og:image:alt")),
        ("twitter:image:alt", firstMetaContent(in: body, nameOrProperty: "twitter:image:alt")),
      ].compactMap { name, value -> (String, String)? in
        guard let value = value?.nilIfEmpty else { return nil }
        return (name, value)
      }

      guard !altCandidates.isEmpty else {
        return DeploymentStatusSignal(
          level: .failed,
          title: "发布页面社交元数据",
          message: "缺少 og:image:alt 或 twitter:image:alt，无法确认社交图 Alt。",
          urlText: expectedURLText
        )
      }

      guard altCandidates.contains(where: { socialText($0.1, matches: expectedImageAltText) }) else {
        let first = altCandidates[0]
        return DeploymentStatusSignal(
          level: .failed,
          title: "发布页面社交元数据",
          message: "\(first.0) 与发布记录封面 Alt 不一致：\(first.1)",
          urlText: socialImageURLText.1
        )
      }

      let matchedPieces = [
        expectedTitle == nil ? nil : "标题",
        expectedSummary == nil ? nil : "摘要",
        "封面 Alt",
        "\(socialImageURLText.0) URL",
      ].compactMap(\.self).joined(separator: "、")
      return DeploymentStatusSignal(
        level: .success,
        title: "发布页面社交元数据",
        message: "社交卡片字段（\(matchedPieces)）已匹配发布记录。",
        urlText: socialImageURLText.1
      )
    }

    let matchedPieces = [
      expectedTitle == nil ? nil : "标题",
      expectedSummary == nil ? nil : "摘要",
      expectedImageAltText == nil ? nil : "封面 Alt",
    ].compactMap(\.self).joined(separator: "、")
    return DeploymentStatusSignal(
      level: .success,
      title: "发布页面社交元数据",
      message: "社交卡片字段（\(matchedPieces)）已匹配发布记录。",
      urlText: expectedURLText
    )
  }

  func absoluteURLText(_ value: String, relativeTo baseURLText: String) -> String? {
    let trimmed = value.trimmedForPublishing
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
      return url.absoluteString
    }
    guard let baseURL = URL(string: baseURLText),
          let resolvedURL = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
          resolvedURL.scheme != nil,
          resolvedURL.host != nil else {
      return nil
    }
    return resolvedURL.absoluteString
  }

  func articlePageSEOSignal(body: String, expectedURLText: String) -> DeploymentStatusSignal {
    let normalizedExpectedURL = normalizedComparableURL(expectedURLText)
    let canonicalURL = firstHTMLAttributeValue(
      in: body,
      element: "link",
      requiredAttributeName: "rel",
      requiredAttributeValue: "canonical",
      outputAttributeName: "href"
    )
    let openGraphURL = firstHTMLAttributeValue(
      in: body,
      element: "meta",
      requiredAttributeName: "property",
      requiredAttributeValue: "og:url",
      outputAttributeName: "content"
    )

    let candidates = [
      ("canonical", canonicalURL),
      ("og:url", openGraphURL),
    ]
    let presentCandidates = candidates.compactMap { name, value -> (String, String)? in
      guard let value = value?.nilIfEmpty else {
        return nil
      }
      return (name, value)
    }

    guard !presentCandidates.isEmpty else {
      return DeploymentStatusSignal(
        level: .unknown,
        title: "发布页面 SEO",
        message: "文章页面缺少 canonical 或 og:url，无法确认社交分享 URL。",
        urlText: expectedURLText
      )
    }

    let mismatches = presentCandidates.filter { _, value in
      normalizedComparableURL(value) != normalizedExpectedURL
    }
    if let mismatch = mismatches.first {
      return DeploymentStatusSignal(
        level: .failed,
        title: "发布页面 SEO",
        message: "\(mismatch.0) 指向 \(mismatch.1)，不是当前文章 URL。",
        urlText: expectedURLText
      )
    }

    let matchedNames = presentCandidates.map(\.0).joined(separator: " / ")
    return DeploymentStatusSignal(
      level: .success,
      title: "发布页面 SEO",
      message: "\(matchedNames) 已指向当前文章 URL。",
      urlText: expectedURLText
    )
  }

  func firstMetaContent(in html: String, nameOrProperty: String) -> String? {
    firstHTMLAttributeValue(
      in: html,
      element: "meta",
      requiredAttributeName: "property",
      requiredAttributeValue: nameOrProperty,
      outputAttributeName: "content"
    )
    ?? firstHTMLAttributeValue(
      in: html,
      element: "meta",
      requiredAttributeName: "name",
      requiredAttributeValue: nameOrProperty,
      outputAttributeName: "content"
    )
  }

  func firstHTMLAttributeValue(
    in html: String,
    element: String,
    requiredAttributeName: String,
    requiredAttributeValue: String,
    outputAttributeName: String
  ) -> String? {
    let elementPattern = "<\\s*\(element)\\b[^>]*>"
    guard let regex = try? NSRegularExpression(pattern: elementPattern, options: [.caseInsensitive]) else {
      return nil
    }
    let source = html as NSString
    let matches = regex.matches(in: html, range: NSRange(location: 0, length: source.length))
    for match in matches {
      let tag = source.substring(with: match.range)
      guard let requiredValue = htmlAttributeValue(named: requiredAttributeName, in: tag),
            requiredValue.caseInsensitiveCompare(requiredAttributeValue) == .orderedSame else {
        continue
      }
      if let outputValue = htmlAttributeValue(named: outputAttributeName, in: tag) {
        return outputValue
      }
    }
    return nil
  }

  func htmlAttributeValue(named name: String, in tag: String) -> String? {
    let escapedName = NSRegularExpression.escapedPattern(for: name)
    let pattern = #"\b"# + escapedName + #"\s*=\s*(['"])(.*?)\1"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
      return nil
    }
    let source = tag as NSString
    guard let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: source.length)),
          match.numberOfRanges >= 3 else {
      return nil
    }
    return source.substring(with: match.range(at: 2))
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
  }

  func normalizedComparableURL(_ value: String) -> String {
    let trimmed = value.trimmedForPublishing
    guard var components = URLComponents(string: trimmed) else {
      return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }
    components.fragment = nil
    var text = components.url?.absoluteString ?? trimmed
    while text.hasSuffix("/") {
      text.removeLast()
    }
    return text.lowercased()
  }

  func socialText(_ actual: String, matches expected: String) -> Bool {
    let actualText = normalizedSocialText(actual)
    let expectedText = normalizedSocialText(expected)
    guard !actualText.isEmpty, !expectedText.isEmpty else {
      return false
    }
    return actualText == expectedText
      || actualText.contains(expectedText)
      || (expectedText.contains(actualText) && actualText.count >= 40)
  }

  func normalizedSocialText(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&#39;", with: "'")
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .lowercased()
  }

  func decodedEndpointStatus(data: Data) -> EndpointStatusPayload? {
    guard !data.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    guard let rawStatus = endpointStatusText(from: object) else {
      return nil
    }
    return EndpointStatusPayload(
      rawStatus: rawStatus,
      level: endpointLevel(from: rawStatus),
      title: endpointStringValue(for: ["title", "name", "deployment", "service"], in: object),
      message: endpointStringValue(for: ["message", "summary", "description", "detail"], in: object),
      urlText: endpointStringValue(for: ["url", "html_url", "deploy_url", "deployment_url"], in: object)
    )
  }

  func endpointStatusText(from object: [String: Any]) -> String? {
    if let bool = object["ok"] as? Bool {
      return bool ? "success" : "failed"
    }
    return endpointStringValue(
      for: ["status", "state", "conclusion", "level", "result", "deployment_status"],
      in: object
    )
  }

  func endpointStringValue(for keys: [String], in object: [String: Any]) -> String? {
    for key in keys {
      if let value = object[key] as? String, let trimmed = value.nilIfEmpty {
        return trimmed
      }
      if let value = object[key] as? NSNumber {
        return value.stringValue
      }
    }
    return nil
  }

  func endpointLevel(from status: String) -> DeploymentStatusLevel {
    switch status.lowercased() {
    case "ok", "success", "succeeded", "ready", "live", "active", "passed", "healthy", "built", "completed":
      return .success
    case "running", "building", "queued", "pending", "processing", "deploying", "in_progress", "waiting":
      return .running
    case "fail", "failed", "failure", "error", "errored", "canceled", "cancelled", "unhealthy", "down":
      return .failed
    default:
      return .unknown
    }
  }


}
