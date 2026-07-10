import Foundation
public struct AIPublishingAssistantService {
  private let client: AIChatCompletionClient

  public init(client: AIChatCompletionClient = AIChatCompletionClient()) {
    self.client = client
  }

  public func perform(
    _ request: AIPublishingActionRequest,
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIPublishingActionResult {
    if config.requiresAPIKey && apiKey?.nilIfEmpty == nil {
      throw AIPublishingAssistantError.missingAPIKey
    }
    let taskConfig = AIChatModelCatalog.config(for: request.kind.aiModelTaskKind, baseConfig: config)

    let completion = AIChatCompletionRequest(
      model: taskConfig.normalizedModel,
      messages: [
        AIChatMessage(role: "system", content: systemPrompt),
        AIChatMessage(role: "user", content: prompt(for: request)),
      ],
      temperature: 0.3
    )
    let result = try await client.complete(
      request: completion,
      config: taskConfig,
      apiKey: apiKey,
      purpose: .utilityTask
    )
    return AIPublishingActionResult(
      kind: request.kind,
      content: result.content,
      providerName: taskConfig.normalizedDisplayName,
      model: result.rawModel?.nilIfEmpty ?? taskConfig.normalizedModel
    )
  }

  public func reply(
    to request: AIPublishingChatRequest,
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIPublishingChatMessage {
    let taskConfig = try chatTaskConfig(for: request, config: config, apiKey: apiKey)
    let completion = AIChatCompletionRequest(
      model: taskConfig.normalizedModel,
      messages: chatMessages(for: request),
      temperature: 0.4
    )
    let result = try await client.complete(
      request: completion,
      config: taskConfig,
      apiKey: apiKey,
      purpose: .interactiveChat
    )
    return AIPublishingChatMessage(
      role: .assistant,
      content: result.content,
      model: result.rawModel?.nilIfEmpty ?? taskConfig.normalizedModel,
      tokenUsage: result.tokenUsage,
      contextMode: request.contextMode
    )
  }

  public func streamReply(
    to request: AIPublishingChatRequest,
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIPublishingChatReplyStream {
    let taskConfig = try chatTaskConfig(for: request, config: config, apiKey: apiKey)
    let completion = AIChatCompletionRequest(
      model: taskConfig.normalizedModel,
      messages: chatMessages(for: request),
      temperature: 0.4
    )
    let updates = try await client.stream(
      request: completion,
      config: taskConfig,
      apiKey: apiKey,
      purpose: .interactiveChat
    )
    return AIPublishingChatReplyStream(
      initialMessage: AIPublishingChatMessage(
        role: .assistant,
        content: "",
        model: taskConfig.normalizedModel,
        contextMode: request.contextMode
      ),
      updates: updates
    )
  }

  private func chatTaskConfig(
    for request: AIPublishingChatRequest,
    config: AIProviderConfig,
    apiKey: String?
  ) throws -> AIProviderConfig {
    if config.requiresAPIKey && apiKey?.nilIfEmpty == nil {
      throw AIPublishingAssistantError.missingAPIKey
    }
    guard let latestUserMessage = request.messages.last(where: { $0.role == .user }),
      latestUserMessage.content.nilIfEmpty != nil || !latestUserMessage.imageAttachments.isEmpty
    else {
      throw AIPublishingAssistantError.emptyChatMessage
    }
    if request.messages.contains(where: { !$0.imageAttachments.isEmpty }), !config.supportsImageInput {
      throw AIPublishingAssistantError.unsupportedImageAttachments(config.normalizedDisplayName)
    }

    var taskConfig = config
    let currentModel = request.selectedModel?.nilIfEmpty ?? config.normalizedModel
    taskConfig.model = AIChatModelCatalog.model(
      for: request.modelGrade,
      config: config,
      currentModel: currentModel
    )
    return taskConfig
  }

  public func suggestMetadata(
    for request: AIPublishingActionRequest,
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIPublishingMetadataSuggestion {
    if config.requiresAPIKey && apiKey?.nilIfEmpty == nil {
      throw AIPublishingAssistantError.missingAPIKey
    }
    let taskConfig = AIChatModelCatalog.config(for: .metadataRepair, baseConfig: config)

    let completion = AIChatCompletionRequest(
      model: taskConfig.normalizedModel,
      messages: [
        AIChatMessage(role: "system", content: metadataSystemPrompt),
        AIChatMessage(role: "user", content: metadataPrompt(for: request)),
      ],
      temperature: 0.25
    )
    let result = try await client.complete(
      request: completion,
      config: taskConfig,
      apiKey: apiKey,
      purpose: .utilityTask
    )
    let suggestion = AIPublishingMetadataSuggestionParser.parse(result.content)
    guard suggestion.hasSuggestions else {
      throw AIPublishingAssistantError.emptyMetadataSuggestion
    }
    return suggestion
  }

  public func suggestImageText(
    for targets: [AIPublishingImageTextTarget],
    profile: SiteProfile,
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> [AIPublishingImageTextSuggestion] {
    let targetBatch = Array(targets.prefix(20))
    guard !targetBatch.isEmpty else {
      throw AIPublishingAssistantError.emptyImageTextTargets
    }
    if config.requiresAPIKey && apiKey?.nilIfEmpty == nil {
      throw AIPublishingAssistantError.missingAPIKey
    }
    let taskConfig = AIChatModelCatalog.config(for: .imageAltCaption, baseConfig: config)

    let completion = AIChatCompletionRequest(
      model: taskConfig.normalizedModel,
      messages: [
        AIChatMessage(role: "system", content: imageTextSystemPrompt),
        AIChatMessage(role: "user", content: imageTextPrompt(for: targetBatch, profile: profile)),
      ],
      temperature: 0.2
    )
    let result = try await client.complete(
      request: completion,
      config: taskConfig,
      apiKey: apiKey,
      purpose: .utilityTask
    )
    let suggestions = AIPublishingImageTextSuggestionParser.parse(result.content, targets: targetBatch)
    guard !suggestions.isEmpty else {
      throw AIPublishingAssistantError.emptyImageTextSuggestions
    }
    return suggestions
  }

  public func prompt(for request: AIPublishingActionRequest) -> String {
    let draft = request.draft
    let context = publishingContext(for: request)

    switch request.kind {
    case .publishingReadiness:
      return """
      \(context)

      请基于当前 Mac 发布工作台上下文，输出一份发布准备建议。只给可执行建议，不要泛泛而谈，不要编造已经完成的线上验证。

      请输出：
      1. 发布前最需要处理的三件事
      2. SEO 标题/摘要建议
      3. 图片/封面与公开风险注意项
      4. PR/MR 描述草稿

      正文节选：
      \(String(draft.bodyMarkdown.prefix(4_000)))
      """
    case .continueArticle:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章上下文续写后续正文，延续原文语气、结构和事实边界。只返回要插入到正文末尾的 Markdown，不重复已有正文，不编造正文没有提供的事实。"
      )
    case .draftOpening:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成一个可直接插入正文开头的 Markdown 开头小节。开头要交代读者问题、文章会解决什么、适用边界和阅读收益；保持克制，不编造正文没有提供的事实。"
      )
    case .sharpenOpeningSelection:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请只优化下面选中的 Markdown 开头段。更快进入主题，明确文章要解决的问题、记录场景或读者收益；保留原意、事实、代码、链接和 Markdown 结构，不写营销式导语，不新增 front matter，只返回优化后的 Markdown 片段。"
      )
    case .draftOpeningHooks:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成 3 到 5 个可选开头钩子。每个钩子要具体、克制、贴合正文事实边界，并说明适合哪类读者。只输出 Markdown，不编造正文没有提供的事实。"
      )
    case .draftFullArticle:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前标题、摘要、标签和正文种子生成一版完整 Markdown 初稿。保留已有观点和事实边界，优先补结构、过渡、示例和结尾；信息不足的位置写“待补充”，不要编造事实、数据或真实链接。"
      )
    case .suggestArticleOutline:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章上下文生成一版可直接插入正文的 Markdown 大纲。包含 2 到 4 个一级小节和必要要点，避免泛泛标题，不编造正文没有提供的事实。"
      )
    case .compareWritingAngles:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前主题比较 3 到 5 个写作角度。每个角度包含目标读者、核心问题、文章结构、可用证据和主要风险。不要联网核验，不要编造不存在的事实或案例。"
      )
    case .expandOutlineToDraft:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请把当前文章中的大纲、要点或草稿骨架扩写成连续 Markdown 正文。保留原有标题顺序和核心观点，补充必要过渡、解释、示例和限制条件；不要编造外部事实、真实数据、链接、账号或私密路径，不新增 front matter。"
      )
    case .draftConclusion:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成一个可直接插入的 Markdown 结尾小节。总结关键结论、限制条件和下一步行动，不重复正文大段内容，不编造正文没有提供的事实。"
      )
    case .draftArticleTLDR:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章上下文生成一个 Markdown 小节，标题为“## TL;DR”。用 3 到 5 条要点概括关键结论、限制条件和读者收益，不编造正文没有提供的事实。"
      )
    case .draftArticleFAQ:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章上下文生成一个 Markdown FAQ 小节。问题应来自读者真实可能困惑的点，回答要克制、可验证，不编造正文没有提供的事实。"
      )
    case .draftReaderQuestions:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成一个 Markdown 小节，标题为“## 读者可能会问”。给出 4 到 7 个读者可能追问的问题，每个问题后补一条简短说明，指出文章哪里还可以补充；问题必须围绕当前文章，不要泛泛而谈，不要编造事实。"
      )
    case .draftTransitionSection:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成一个可插入在两个主题之间的 Markdown 过渡段。说明上一部分和下一部分的关系、读者为什么需要继续看、哪些前提仍需保留；不要重复正文大段内容，不编造事实。"
      )
    case .draftExampleSection:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成一个示例小节，用来帮助读者理解正文已有概念、流程或判断。示例只能使用正文已经提供的事实和场景；缺少具体数据时写“待补充”，不要编造公司、人物、价格或真实案例。"
      )
    case .draftStepByStepGuide:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请把当前文章可操作的部分整理成 Markdown 步骤指南。步骤要有顺序、输入、预期结果和注意事项；缺少条件时写“待确认”，不要编造工具输出或已完成验证。"
      )
    case .draftTutorialVersion:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请把当前文章改写成教程版 Markdown 草稿。保留已有事实和结论，按“适用场景 / 准备条件 / 操作步骤 / 验证方式 / 常见问题”组织；缺少命令、环境或验证结果时写“待确认”，不要编造工具输出，不新增 front matter。"
      )
    case .draftChecklistSection:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成一个 Markdown 检查清单小节。使用 - [ ] 任务列表格式，每一项都要具体、可检查，并围绕当前文章场景；不要加入与主题无关的通用事项，不要编造正文没有提供的任务，不新增 front matter。"
      )
    case .draftTroubleshootingSection:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成一个 Markdown 故障排查小节。按“现象 / 可能原因 / 如何确认 / 处理建议”组织；只使用正文已有信息，缺少日志、命令或环境时标为“待确认”，不要编造命令输出。"
      )
    case .draftCodeExample:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成一个代码示例小节。代码必须与正文技术语境一致，优先使用伪代码或最小可读示例；如果正文没有足够 API、语言或环境信息，请明确写出待确认项，不要编造可运行性。"
      )
    case .draftMermaidDiagram:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成一个 Mermaid 图示小节。只表达正文已经提供的流程、依赖或决策关系；节点名称要简短，缺失关系不要臆测。输出 Markdown fenced mermaid 代码块和一句使用说明。"
      )
    case .draftGlossary:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成一个 Markdown 术语表小节。提取 5 到 12 个关键术语，每个术语用一行解释它在本文里的含义；只解释正文能支持的概念，不要编造正文没有支持的定义，不确定的术语标注“待确认”，不新增 front matter。"
      )
    case .draftReferencesSection:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成一个参考资料清单小节。不要编造真实链接；只列出需要作者补充来源的位置、建议寻找的来源类型、应验证的问题，以及临时可降级的表达方式。"
      )
    case .draftInterviewQA:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成访谈式问答 Markdown 小节。生成 5 到 8 组问答，问题要像读者、作者复盘或采访中真实会问的问题；回答要短、具体、忠于正文，不要编造事实、承诺或外部来源。"
      )
    case .reorganizeStructure:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成结构重排建议。先指出当前结构的主要问题，再给出推荐的新段落顺序和每段写作要点；不要直接重写全文，不新增 front matter，不要编造事实，只返回可插入临时笔记区的 Markdown 建议。"
      )
    case .draftCounterpointSection:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章补充反方观点、限制和反例小节。列出 3 到 5 个可能的反方观点、边界条件、失败场景或不适用场景；每一点都要服务当前文章主题，避免为了辩论而编造事实。"
      )
    case .draftCaseStudySection:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成一个案例分析小节。案例要贴合当前主题，包含背景、做法、结果或复盘；不要编造真实客户、真实数据、真实账号或私密路径。上下文不足时使用“假设场景”并明确标注需要作者确认。"
      )
    case .extractArticleKeyPoints:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章上下文提取关键要点，输出一个可直接插入正文的 Markdown 列表。只保留重要事实、结论、约束和风险，不添加解释，不编造事实。"
      )
    case .extractArticleActionItems:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章上下文提取可执行行动项，输出 Markdown 任务列表。每一项都要能从正文推导，不编造正文没有提供的任务或完成状态。"
      )
    case .rewriteSelection:
      return """
      \(context)

      请只改写下面选中的 Markdown 文本，保持事实、代码、链接和 Markdown 结构，不添加解释。没有选中文本时，返回一句提示让用户先选择文本。

      选中文本：
      \(request.selectedText?.nilIfEmpty ?? "")
      """
    case .polishSelection:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请只润色下面选中的 Markdown 文本，让表达更自然、清楚、克制。保留事实、代码、链接、Front Matter 片段和 Markdown 结构，不新增正文没有的事实，不添加解释。"
      )
    case .expandSelection:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请只扩写下面选中的 Markdown 文本，补足必要上下文、步骤、边界和读者理解所需说明。保留事实、代码、链接和 Markdown 结构，不编造正文没有提供的事实，不添加解释。"
      )
    case .continueAfterSelection:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请基于下面选中的 Markdown 文本续写后续内容，延续原文语气和上下文。只返回要插入到选区后面的 Markdown，不重复选中文本，不编造正文没有提供的事实。"
      )
    case .condenseSelection:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请只压缩下面选中的 Markdown 文本，删除重复和绕远表达，保留关键事实、限制条件、代码、链接和 Markdown 结构。输出可直接替换选区的 Markdown，不添加解释。"
      )
    case .removeRedundancySelection:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请只删减下面选中的 Markdown 文本里的冗余、重复、口水话和绕远表达。保留关键事实、判断依据、代码、链接和 Markdown 结构，输出可直接替换选区的 Markdown，不添加解释。"
      )
    case .checklistSelection:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请把下面选中的 Markdown 文本整理成可执行检查清单。使用 Markdown 任务列表，保留原有事实、步骤、代码和链接，不编造缺失条件；如果原文不适合转清单，请给出最接近的结构化清单。"
      )
    case .comparisonTableSelection:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请把下面选中的 Markdown 文本整理成 Markdown 对比表。只使用原文已经给出的维度、对象、条件和结论；缺失项写“待确认”，不编造事实，不添加表格外解释。"
      )
    case .explainSelection:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请解释下面选中的 Markdown 文本，补齐读者理解所需的前提、术语和边界。只返回要插入到选区后面的 Markdown 说明，不重复选中文本，不要编造正文没有提供的事实。"
      )
    case .simplifySelection:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请把下面选中的 Markdown 文本改写得更容易理解，降低术语密度，补足必要上下文。保留事实、代码、链接和 Markdown 结构，不改变结论，不编造事实，不添加解释。"
      )
    case .summarizeSelection:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请把下面选中的 Markdown 文本压缩成清晰摘要，保留关键事实、结论、限制条件、代码或链接引用。只返回可直接替换选区的 Markdown 摘要，不添加解释。"
      )
    case .translateSelectionToChinese:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请把下面选中的 Markdown 文本翻译成自然中文，适合个人网站或技术博客发布。保留 Markdown、代码、链接、文件路径和专有名词；不添加解释。"
      )
    case .translateSelectionToEnglish:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请把下面选中的 Markdown 文本翻译成自然英文，适合技术博客或个人网站发布。保留 Markdown、代码、链接、文件路径和专有名词；不添加解释。"
      )
    case .draftBilingualRewrite:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请把下面选中的 Markdown 片段整理成中英文两个版本。保留代码、链接、图片引用、表格、专有名词和 Markdown 结构；中文版本自然克制，英文版本适合技术博客或个人网站阅读。如有不适合直译的表达，在末尾用“译法提醒”列出 1 到 3 条；不要新增 front matter，不扩展成完整文章。"
      )
    case .fixSelectionGrammar:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请只修正下面选中的 Markdown 文本里的语法、拼写、标点和不通顺表达。尽量不改变原意，保留 Markdown、代码和链接，不添加解释。"
      )
    case .rewriteSelectionReaderFriendly:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请把下面选中的 Markdown 文本改写为读者友好版本，减少跳跃表达，增强衔接和可读性。保留事实、代码、链接和 Markdown 结构，不新增正文没有的事实，不添加解释。"
      )
    case .rewriteSelectionFormal:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请把下面选中的 Markdown 文本改写为更正式、克制、适合公开发布的语气。保留事实、代码、链接和 Markdown 结构，不新增正文没有的事实，不添加解释。"
      )
    case .rewriteSelectionCasual:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请把下面选中的 Markdown 文本改写为更轻松自然但仍适合个人网站发布的语气。保留事实、代码、链接和 Markdown 结构，不新增正文没有的事实，不添加解释。"
      )
    case .rewriteSelectionTechnical:
      return selectedTextPrompt(
        context: context,
        request: request,
        instruction: "请把下面选中的 Markdown 文本改写为更适合技术读者的表达，强化术语准确性、步骤边界和工程语境。保留事实、代码、链接和 Markdown 结构，不新增正文没有的事实，不添加解释。"
      )
    case .draftBilingualMetadata:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: """
        请基于当前文章生成中英文发布元数据候选，输出一个 Markdown 小节，标题为“## 中英元数据候选”。

        必须包含：
        1. 中文标题 3 个、英文标题 3 个
        2. 中文摘要 2 条、英文摘要 2 条
        3. 社交描述中文 1 条、英文 1 条
        4. 可选 slug 3 个和 tags 5 到 8 个

        要求具体、克制、忠于正文和当前 front matter；不要营销化，不要夸大文章价值，不要新增 front matter，不要直接改正文或元数据。只返回 Markdown 候选清单，不添加解释。
        """
      )
    case .suggestTitles:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成 5 个标题候选，每行一个。标题要具体、清楚，适合静态博客文章；不要使用引号、编号解释、front matter 或正文，不要夸大文章价值。"
      )
    case .suggestSlug:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成 5 个 slug 候选，每行一个。使用小写 kebab-case，只包含小写英文字母、数字和连字符；不要包含日期、文件扩展名、路径分隔符、引号、编号、front matter 或解释。slug 要短、稳定、可读。"
      )
    case .suggestSummary:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成一条 summary/description。摘要要具体、克制，适合静态博客列表页、RSS 和社交分享；长度控制在 60 到 160 个中文字符，或 25 到 45 个英文单词。不要使用引号、编号、Markdown、front matter 或解释，只返回一条摘要文本。"
      )
    case .suggestTags:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成 3 到 8 个 tags 候选，每行一个。tags 要短、稳定、可复用，避免泛泛的“随笔”“记录”等弱标签；优先复用当前文章已有技术名词、项目名和主题名。不要使用编号、引号、Markdown、front matter 或解释。"
      )
    case .draftFrontMatterPack:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: """
        请基于当前文章生成 Front Matter 候选套餐，输出一个 Markdown 小节，标题为“## Front Matter 套餐”。

        必须包含：
        1. 标题候选 3 个
        2. slug 候选 3 个，小写 kebab-case，不含日期、路径或扩展名
        3. summary/description 候选 2 条
        4. tags 候选 5 到 8 个
        5. 需要作者确认的字段或风险

        只生成候选清单，不直接新增 front matter，不改正文，不编造文章没有的事实。
        """
      )
    case .titleSummaryTags:
      if let selectedText = request.selectedText?.nilIfEmpty {
        return """
        \(context)

        请基于下面选中的 Markdown 文本，输出适合个人网站发布的摘要、可用小标题和 tags 建议。用简洁 Markdown 列表，不要泛泛而谈，不要改写全文。

        选中文本：
        \(String(selectedText.prefix(4_000)))
        """
      }

      return """
      \(context)

      请基于当前文章，输出适合个人网站发布的标题、摘要、slug、tags 建议。用简洁 Markdown 列表，不要泛泛而谈。

      正文节选：
      \(String(draft.bodyMarkdown.prefix(4_000)))
      """
    case .privacyReview:
      if let selectedText = request.selectedText?.nilIfEmpty {
        return """
        \(context)

        请只检查下面选中的 Markdown 文本是否有不适合公开发布的内容，包括密钥、内网地址、个人隐私、客户信息、未公开业务数据、调试路径。按风险等级列出，并给出可执行修改建议。

        选中文本：
        \(String(selectedText.prefix(8_000)))
        """
      }

      return """
      \(context)

      请检查这篇文章是否有不适合公开发布的内容，包括密钥、内网地址、个人隐私、客户信息、未公开业务数据、调试路径。按风险等级列出，并给出可执行修改建议。

      正文：
      \(String(draft.bodyMarkdown.prefix(8_000)))
      """
    case .reviewContentGaps:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请检查当前文章的内容缺口。按“缺口 / 为什么影响发布 / 需要补充的证据或段落 / 建议插入位置”输出 Markdown 表格。不要把未提供的事实当成已经存在。"
      )
    case .flagUnsupportedClaims:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成事实边界提醒，输出 Markdown 小节标题“## 事实边界提醒”。标出可能缺少来源、过度概括、数字或结论无依据、因果关系跳跃、效果承诺过强的句子；不要联网查证，不要替作者补外部来源。每条给出“为什么需要确认”和“建议怎么改得更稳”；没有明显问题时写“未发现明显事实边界问题”。"
      )
    case .draftSourceChecklist:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请为当前文章生成来源补充清单。按“需要来源的位置 / 应验证的问题 / 合适来源类型 / 临时保守表述”输出 Markdown 表格。不要编造真实链接、论文、官方文档或已经完成的核验。"
      )
    case .suggestInternalLinks:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请给当前文章生成内链建议。只能基于上下文里已经出现的站点结构、发布路径、标签、分类和文章主题推导；不要编造不存在的真实路径。若没有足够站内文章信息，请输出需要补充的候选文章清单标准。"
      )
    case .auditLinkQuality:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请检查当前文章中的链接质量。按“链接或引用位置 / 风险 / 如何人工确认 / 建议改法”输出 Markdown 表格。不要声称已经访问外部网页，不要编造 HTTP 状态、发布时间或页面内容。"
      )
    case .auditImagePrivacy:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章和图片上下文生成图片隐私检查，输出 Markdown 小节标题“## 图片隐私检查”。检查 Markdown 图片引用、封面、文件名、路径和图片工作台信息里可能暴露的个人信息、客户信息、内部界面、地理位置、账号、token、私密路径或未公开业务内容。不要假装看到了图片真实画面；只能基于文件名、引用位置、正文上下文和图片检查信息判断，不确定的地方标“需要人工确认”。"
      )
    case .reviewSSGCompatibility:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请检查当前文章对静态博客框架的兼容性，覆盖 Hexo、Hugo、Zola、Astro、Jekyll 常见 front matter、摘要、图片路径、短代码和 Markdown 语法风险。只基于当前文章和站点配置判断，缺少信息写“待确认”。"
      )
    case .reviewSEOReadability:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请检查当前文章的 SEO 与可读性。输出标题、摘要、首屏、结构层级、关键词自然度、读者理解门槛和可执行修改建议。不要承诺搜索排名，不要编造线上数据。"
      )
    case .reviewReaderClarity:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请从目标读者角度检查当前文章清晰度。输出读者可能卡住的位置、缺少的前提、跳跃的段落、术语解释建议和可直接插入的过渡句。不要改变文章结论，不要补正文没有依据的事实。"
      )
    case .reviewTechnicalAccuracy:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请检查当前文章的技术准确性风险。按“表述 / 风险类型 / 需要验证的证据 / 建议保守改写”输出 Markdown 表格。不要假装运行过代码、命令或测试；无法确认的地方明确写“待验证”。"
      )
    case .draftImageAltCaptions:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章和图片上下文生成图片 alt/caption 建议。不能假装看到了图片内容；只能根据文件名、引用位置、正文上下文和图片检查信息推断。输出每张图片的 alt、caption、保守理由和需要人工确认的点。"
      )
    case .draftSocialShare:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成社交分享文案。分别给出 X/微博短文案、长文案、LinkedIn/公众号式摘要和 3 个可选开头。不要夸大结论，不要编造读者反馈或发布数据。"
      )
    case .draftPublishAssetPack:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请生成发布素材包：SEO 标题备选、社交摘要、摘录卡片文案、Newsletter 摘要、图片 alt/caption 注意项和发布检查清单。所有内容必须基于当前文章，不要编造验证结果。"
      )
    case .draftPullQuotes:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请从当前文章中提炼可引用摘录。输出 6 到 10 条短摘录，每条包含适用渠道、原文依据位置和是否需要人工确认。只能改写正文已经表达的观点，不要制造更强结论或虚构金句。"
      )
    case .draftPublishNote:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成发布说明和提交文案，输出 Markdown 小节标题“## 发布说明”。包含一句发布摘要、3 到 5 条变更要点、一个简短 commit message 候选。语气要具体、克制，适合个人网站文章发布或 Git 提交；不要凭空补充正文没有体现的改动，不要新增 front matter。"
      )
    case .draftNewsletterSummary:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成 Newsletter 摘要。包含一句话导读、3 条要点、适合邮件开头的短段落和一个克制 CTA。不要夸大价值，不要编造用户反馈、阅读量或外部验证。"
      )
    case .draftCoverImagePrompt:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成封面图提示词。输出 4 个方向：技术说明、工作流场景、抽象概念、极简信息图。提示词要避免真实人物肖像、品牌侵权和无法确认的产品画面。"
      )
    case .draftCrossPlatformAnnouncement:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成跨平台发布摘要，输出 Markdown 小节标题“## 跨平台发布摘要”。包含网站列表页摘要、RSS 摘要、社交短文、较长社交说明和 commit message 候选。每个版本都要具体、克制，忠于文章内容；不要营销化、不要夸大效果、不要新增 front matter。"
      )
    case .draftShortVideoScript:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成短视频口播稿，输出 Markdown 小节标题“## 短视频口播稿”。包含 15 秒、30 秒、60 秒三个版本，每个版本都要有开场句、核心要点和结尾引导。只使用当前文章能支持的信息；不要编造演示画面、用户反馈、数据、外部验证或夸张承诺。"
      )
    case .suggestSeriesPlan:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章规划系列文章。输出系列主题、建议文章标题、每篇读者收益、与当前文章的衔接、复用标签和内链位置。不要编造站内已经存在的文章路径。"
      )
    case .draftContentRefreshPlan:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请为当前文章生成旧文升级计划。输出需要更新的段落类型、过期风险、可补证据、重写建议、发布前检查和回归验证清单。不要声称已经检查线上链接或外部资料。"
      )
    case .draftUpdateNote:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请为当前文章生成更新说明。包含更新摘要、影响范围、读者需要重新看的部分、仍需验证的事项和发布备注。不要编造版本号、发布日期、线上状态或已经完成的验证。"
      )
    case .draftCommentReply:
      return articleDraftPrompt(
        context: context,
        request: request,
        instruction: "请基于当前文章生成评论回复草稿，输出 Markdown 小节标题“## 评论回复草稿”。给出 3 种回复：感谢补充、澄清误解、引导继续阅读或后续更新。每种回复都要短、自然、可复制，避免争辩式语气；不要编造评论者身份、外部事实、链接或文章中不存在的承诺。"
      )
    case .pullRequestDescription:
      return """
      \(context)

      请生成 PR/MR 描述，包含发布内容、改动文件、检查清单和风险说明。不要编造已经完成的线上验证。

      当前 Review 草稿：
      \(request.remoteReviewDraft?.body ?? "无。")
      """
    }
  }

  private var systemPrompt: String {
    "你是个人网站发布控制台里的发布上下文助手。你不做泛聊天，只围绕当前文章、站点结构、front matter、SEO、公开风险、图片和发布说明给建议。"
  }

  private var chatSystemPrompt: String {
    "你是个人网站发布控制台里的文章讨论助手。可以连续对话，但所有回答都必须服务于当前文章、站点结构、front matter、SEO、公开风险、图片和发布流程；不要编造没有给出的仓库状态或线上验证。"
  }

  private var generalChatSystemPrompt: String {
    """
    你是通用 AI 对话助手。
    可以回答写作、技术、学习、工具使用和开放问题，不要把回答限制在个人网站或当前文章内容里。
    回答要直接、具体、可执行；如果用户的问题需要当前文章、站点仓库、部署状态或本地文件内容，必须说明当前通用聊天没有这些上下文，不要编造。
    """
  }

  private var metadataSystemPrompt: String {
    "你是个人网站 front matter 编辑助手。你只生成可供用户确认后写入的标题、slug、summary 和 tags 候选，不直接改正文，不编造文章没有的事实。"
  }

  private var imageTextSystemPrompt: String {
    """
    你是个人网站图片无障碍和 SEO 编辑助手。
    用户只提供文章上下文、文件名、图片路径和现有 Markdown 引用；你不能假装看到了图片内容。
    请基于上下文生成克制、准确、可发布的 alt 文本和 caption 建议。
    alt 应描述图片在文章中的作用，不要堆关键词，不要超过 80 个中文字符；如果无法确认画面内容，用“用于说明...”这类保守表达。
    caption 可作为人工选择项，简短说明图片和文章段落的关系；没有必要时可为空字符串。
    只返回 JSON，不要 Markdown 代码块，不要解释。
    JSON schema:
    {
      "items": [
        {
          "id": "用户提供的图片 ID",
          "alt": "建议 alt 文本",
          "caption": "建议 caption",
          "reason": "为什么这样写"
        }
      ]
    }
    """
  }

  private func metadataPrompt(for request: AIPublishingActionRequest) -> String {
    let draft = request.draft
    let context = publishingContext(for: request)
    return """
    \(context)

    请基于当前文章生成可写入 Front Matter 的元数据候选。只输出下面四个字段块，不要输出解释、Markdown 表格或额外前后文：

    TITLE:
    - 给出 3 到 5 个候选标题

    SLUG:
    - 给出 3 到 5 个小写 kebab-case 候选，不要包含日期、路径或扩展名

    SUMMARY:
    一条 60 到 160 个中文字符，或 25 到 45 个英文单词的摘要

    TAGS:
    - 给出 3 到 8 个短、稳定、可复用的 tags

    当前正文节选：
    \(String(draft.bodyMarkdown.prefix(5_000)))
    """
  }

  private func selectedTextPrompt(
    context: String,
    request: AIPublishingActionRequest,
    instruction: String
  ) -> String {
    """
    \(context)

    \(instruction)
    没有选中文本时，返回一句提示让用户先选择文本。

    选中文本：
    \(request.selectedText?.nilIfEmpty ?? "")
    """
  }

  private func articleDraftPrompt(
    context: String,
    request: AIPublishingActionRequest,
    instruction: String
  ) -> String {
    let draft = request.draft
    return """
    \(context)

    \(instruction)
    当前文章没有足够上下文时，返回一句提示让用户先补充标题、摘要或正文。

    当前文章：
    标题：\(draft.title.nilIfEmpty ?? "未设置")
    摘要：\(draft.summary.nilIfEmpty ?? "未设置")
    Tags：\(draft.tags.isEmpty ? "未设置" : draft.tags.joined(separator: ", "))

    正文节选：
    \(String(draft.bodyMarkdown.prefix(5_000)))
    """
  }

  private func imageTextPrompt(
    for targets: [AIPublishingImageTextTarget],
    profile: SiteProfile
  ) -> String {
    """
    站点：\(profile.name)（\(profile.siteKind.displayName)）
    AI 写作风格：
    \(profile.aiWritingStylePromptInstructions)

    图片候选：
    \(targets.map(imageTextTargetPromptLine).joined(separator: "\n"))
    """
  }

  private func imageTextTargetPromptLine(_ target: AIPublishingImageTextTarget) -> String {
    """
    - id: \(target.id)
      article_title: \(target.draftTitle)
      markdown_path: \(target.markdownPath)
      summary: \(target.articleSummary.isEmpty ? "未设置" : target.articleSummary)
      filename: \(target.filename)
      image_path: \(target.imagePath)
      existing_alt: \(target.existingAlt.isEmpty ? "空" : target.existingAlt)
      existing_caption: \(target.existingCaption.isEmpty ? "空" : target.existingCaption)
      role: \(target.isCover ? "cover" : "inline")
      referenced_in_markdown: \(target.isReferencedInMarkdown ? "yes" : "no")
      article_excerpt: \(String(target.articleExcerpt.prefix(900)))
    """
  }

  private func chatMessages(for request: AIPublishingChatRequest) -> [AIChatMessage] {
    if request.contextMode == .general {
      return [
        AIChatMessage(role: "system", content: generalChatSystemPrompt)
      ] + request.messages.suffix(12).map {
        AIChatMessage(role: $0.role.rawValue, content: chatContent(for: $0))
      }
    }

    let actionContext = AIPublishingActionRequest(
      kind: .publishingReadiness,
      draft: request.draft,
      profile: request.profile,
      preflightIssues: request.preflightIssues,
      publishPackage: request.publishPackage,
      remoteReviewDraft: request.remoteReviewDraft,
      workflowContext: request.workflowContext
    )
    let context = publishingContext(for: actionContext)
    let focusedParagraphContext = request.focusedParagraph.map { paragraph in
      """

      聚焦段落：
      标题：\(paragraph.title)
      内容：
      \(String(paragraph.text.prefix(2_000)))
      """
    } ?? ""
    let relatedSuggestionsContext = relatedSuggestionsContext(request.relatedSuggestions)
    let contextMessage = """
    当前 Mac 工作台上下文：
    \(context)
    \(focusedParagraphContext)
    \(relatedSuggestionsContext)

    正文节选：
    \(String(request.draft.bodyMarkdown.prefix(4_000)))
    """

    var messages = [
      AIChatMessage(role: "system", content: chatSystemPrompt),
      AIChatMessage(role: "system", content: contextMessage),
    ]
    messages.append(
      contentsOf: request.messages.suffix(12).map {
        AIChatMessage(role: $0.role.rawValue, content: chatContent(for: $0))
      }
    )
    return messages
  }

  private func relatedSuggestionsContext(_ suggestions: [SiteRelationSuggestion]) -> String {
    let lines = suggestions.prefix(5).map { suggestion in
      let labels = suggestion.sharedLabels.isEmpty ? "无共享标签/分类" : suggestion.sharedLabels.joined(separator: "、")
      return "- \(suggestion.targetTitle) (\(suggestion.targetPath))：\(suggestion.reason)；共享：\(labels)"
    }
    guard !lines.isEmpty else { return "" }
    return """

    站内关联建议（只作为候选上下文，不要编造不存在的链接）：
    \(lines.joined(separator: "\n"))
    """
  }

  private func chatContent(for message: AIPublishingChatMessage) -> AIChatMessageContent {
    guard message.role == .user, !message.imageAttachments.isEmpty else {
      return .text(message.content)
    }

    var parts: [AIChatMessageContentPart] = []
    let text = message.content.trimmedForPublishing
    if !text.isEmpty {
      parts.append(.text(text))
    }
    parts.append(contentsOf: message.imageAttachments.map { .imageURL($0.dataURL) })
    return .parts(parts)
  }

  private func publishingContext(for request: AIPublishingActionRequest) -> String {
    let draft = request.draft
    let profile = request.profile
    let issues = request.preflightIssues
      .filter { $0.severity != .info }
      .map { "- \($0.severity.displayName)：\($0.title) - \($0.message)" }
      .joined(separator: "\n")
    let files = request.publishPackage?.files
      .map { "- \($0.kind.displayName): \($0.repositoryPath)" }
      .joined(separator: "\n") ?? "无发布包。"
    let workflowContext = workflowContextSummary(request.workflowContext)

    return """
    站点：\(profile.name)（\(profile.siteKind.displayName)）
    仓库：\(profile.repositoryDisplayName)
    AI 写作风格：
    \(profile.aiWritingStylePromptInstructions)
    文章标题：\(draft.title)
    Slug：\(draft.slug)
    摘要：\(draft.summary)
    标签：\(draft.tags.joined(separator: ", "))
    分类：\(draft.categories.joined(separator: ", "))
    发布路径：\(profile.markdownPath(for: draft))
    发布文件：
    \(files)
    发布检查：
    \(issues.isEmpty ? "无阻塞问题。" : issues)
    Mac 发布上下文：
    \(workflowContext)
    """
  }

  private func workflowContextSummary(_ context: AIPublishingWorkflowContext?) -> String {
    guard let context else {
      return "未生成本地发布上下文。"
    }

    var sections: [String] = []
    sections.append(localPublishPreviewSummary(context.publishPreview))
    sections.append(localSitePreviewSummary(context.localSitePreviewPlan))
    sections.append(imageReportSummary(context.imageReport))
    return sections.joined(separator: "\n")
  }

  private func localPublishPreviewSummary(_ preview: LocalPublishPreview?) -> String {
    guard let preview else {
      return "本地 diff：未生成。"
    }

    let changed = preview.changedFileDiffs
    let changedLines = changed.prefix(8).map {
      "- \($0.kind.displayName) \($0.status.displayName)：\($0.path)"
    }
    let issueLines = preview.issues.prefix(4).map {
      "- \($0.severity.displayName)：\($0.title) - \($0.message)"
    }

    var lines = ["本地 diff：\(changed.count) 个待写入变化。"]
    lines.append(contentsOf: changedLines)
    if !issueLines.isEmpty {
      lines.append("Diff 问题：")
      lines.append(contentsOf: issueLines)
    }
    return lines.joined(separator: "\n")
  }

  private func localSitePreviewSummary(_ plan: LocalSitePreviewPlan?) -> String {
    guard let plan else {
      return "本地预览：未配置。"
    }

    var lines = [
      "本地预览：\(plan.siteKind.displayName) \(plan.previewURL.absoluteString)",
      "- 命令：\(plan.command)",
    ]
    lines.append(contentsOf: plan.notes.prefix(3).map { "- \($0)" })
    return lines.joined(separator: "\n")
  }

  private func imageReportSummary(_ report: ImageWorkbenchReport?) -> String {
    guard let report else {
      return "图片检查：未生成。"
    }

    var lines = [
      "图片检查：\(report.items.count) 张图片，缺 alt \(report.missingAltTextCount)，源图缺失 \(report.missingSourceCount)，可压缩 JPEG \(report.optimizableJPEGCount)。",
      "封面：\(report.coverStatus.state.displayName)",
    ]

    if let field = report.coverStatus.frontMatterFieldPath {
      lines.append("- Front Matter：\(field)")
    }
    if let publishPath = report.coverStatus.relativePublishPath {
      lines.append("- 公开路径：\(publishPath)")
    }
    if let repositoryPath = report.coverStatus.repositoryPath {
      lines.append("- 仓库路径：\(repositoryPath)")
    }

    let issueLines = report.issues
      .filter { $0.title != "还没有图片" }
      .prefix(4)
      .map { "- \($0.severity.displayName)：\($0.title) - \($0.message)" }
    if !issueLines.isEmpty {
      lines.append("图片问题：")
      lines.append(contentsOf: issueLines)
    }

    return lines.joined(separator: "\n")
  }
}

public enum AIPublishingAssistantError: LocalizedError, Equatable {
  case missingAPIKey
  case emptyChatMessage
  case unsupportedImageAttachments(String)
  case emptyMetadataSuggestion
  case emptyImageTextTargets
  case emptyImageTextSuggestions

  public var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "请先在 Settings 的 AI 页保存 API Key。"
    case .emptyChatMessage:
      return "请先输入要发送给 AI 的内容。"
    case .unsupportedImageAttachments(let providerName):
      return "\(providerName) 当前接口不支持图片输入，请切换到支持视觉输入的 OpenAI-compatible 模型。"
    case .emptyMetadataSuggestion:
      return "AI 没有返回可应用的元数据建议。"
    case .emptyImageTextTargets:
      return "当前文章没有需要生成 alt/caption 的图片。"
    case .emptyImageTextSuggestions:
      return "AI 没有返回可应用的图片 alt/caption 建议。"
    }
  }
}
