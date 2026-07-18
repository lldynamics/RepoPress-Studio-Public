import CryptoKit
import Foundation

public enum DraftStatus: String, Codable, CaseIterable, Identifiable, Sendable {
  case draft
  case ready
  case published
  case failed

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .draft:
      return "草稿"
    case .ready:
      return "待发布"
    case .published:
      return "已发布"
    case .failed:
      return "失败"
    }
  }

  public var systemImage: String {
    switch self {
    case .draft:
      return "square.and.pencil"
    case .ready:
      return "paperplane"
    case .published:
      return "checkmark.seal"
    case .failed:
      return "xmark.octagon"
    }
  }
}

public enum ArticleVisibility: String, Codable, CaseIterable, Identifiable, Sendable {
  case `public`
  case `private`

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .public:
      return "公开"
    case .private:
      return "私密"
    }
  }

  public var systemImage: String {
    switch self {
    case .public:
      return "globe"
    case .private:
      return "lock"
    }
  }
}

public struct DraftAttachment: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var originalFilename: String
  public var relativePublishPath: String
  public var repositoryPath: String
  public var altText: String
  public var caption: String
  public var byteSize: Int64
  public var sourceFilePath: String?
  public var repositorySHA: String?

  public init(
    id: UUID = UUID(),
    originalFilename: String,
    relativePublishPath: String,
    repositoryPath: String,
    altText: String = "",
    caption: String = "",
    byteSize: Int64 = 0,
    sourceFilePath: String? = nil,
    repositorySHA: String? = nil
  ) {
    self.id = id
    self.originalFilename = originalFilename
    self.relativePublishPath = relativePublishPath
    self.repositoryPath = repositoryPath
    self.altText = altText
    self.caption = caption
    self.byteSize = byteSize
    self.sourceFilePath = sourceFilePath
    self.repositorySHA = repositorySHA
  }
}

public struct GeneralDraftReuseSourceSnapshot: Codable, Hashable, Sendable {
  public var draftID: UUID
  public var sourceProfileName: String
  public var repositoryPath: String?
  public var title: String
  public var slug: String
  public var summary: String
  public var tags: [String]
  public var categories: [String]
  public var draft: Bool
  public var status: DraftStatus
  public var bodyMarkdown: String
  public var capturedAt: Date

  public init(
    draftID: UUID,
    sourceProfileName: String,
    repositoryPath: String?,
    title: String,
    slug: String,
    summary: String,
    tags: [String],
    categories: [String],
    draft: Bool,
    status: DraftStatus,
    bodyMarkdown: String,
    capturedAt: Date = Date()
  ) {
    self.draftID = draftID
    self.sourceProfileName = sourceProfileName
    self.repositoryPath = repositoryPath
    self.title = title
    self.slug = slug
    self.summary = summary
    self.tags = tags
    self.categories = categories
    self.draft = draft
    self.status = status
    self.bodyMarkdown = bodyMarkdown
    self.capturedAt = capturedAt
  }

  public static func make(from draft: ArticleDraft, sourceProfileName: String) -> GeneralDraftReuseSourceSnapshot {
    GeneralDraftReuseSourceSnapshot(
      draftID: draft.id,
      sourceProfileName: sourceProfileName,
      repositoryPath: draft.repositoryPath,
      title: draft.title,
      slug: draft.slug,
      summary: draft.summary,
      tags: draft.tags,
      categories: draft.categories,
      draft: draft.draft,
      status: draft.status,
      bodyMarkdown: draft.bodyMarkdown
    )
  }
}

public struct ArticleDraft: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var siteProfileID: UUID
  public var title: String
  public var date: Date
  public var slug: String
  public var tags: [String]
  public var categories: [String]
  public var authors: [String]
  public var draft: Bool
  public var visibility: ArticleVisibility
  public var summary: String
  public var coverAttachmentID: UUID?
  public var bodyMarkdown: String
  public var attachments: [DraftAttachment]
  public var status: DraftStatus
  public var createdAt: Date
  public var updatedAt: Date
  public var repositoryPath: String?
  public var repositorySHA: String?
  /// Fingerprint of the repository content at the last successful import or
  /// direct publish. It intentionally stays unchanged while the user edits so
  /// background sync can prove that an existing draft is safe to replace.
  public var repositoryImportFingerprint: String?
  public var reusedFromSourceSnapshot: GeneralDraftReuseSourceSnapshot?
  /// Stable identity for built-in software guides. This is intentionally
  /// independent from the editable title and slug so user content with the
  /// same slug is never mistaken for an installed guide.
  public var softwareGuideID: String?

  public init(
    id: UUID = UUID(),
    siteProfileID: UUID,
    title: String,
    date: Date = Date(),
    slug: String = "",
    tags: [String] = [],
    categories: [String] = [],
    authors: [String] = [],
    draft: Bool = true,
    visibility: ArticleVisibility = .public,
    summary: String = "",
    coverAttachmentID: UUID? = nil,
    bodyMarkdown: String = "",
    attachments: [DraftAttachment] = [],
    status: DraftStatus = .draft,
    createdAt: Date = Date(),
    updatedAt: Date = Date(),
    repositoryPath: String? = nil,
    repositorySHA: String? = nil,
    repositoryImportFingerprint: String? = nil,
    reusedFromSourceSnapshot: GeneralDraftReuseSourceSnapshot? = nil,
    softwareGuideID: String? = nil
  ) {
    self.id = id
    self.siteProfileID = siteProfileID
    self.title = title
    self.date = date
    self.slug = slug
    self.tags = tags
    self.categories = categories
    self.authors = authors
    self.draft = draft
    self.visibility = visibility
    self.summary = summary
    self.coverAttachmentID = coverAttachmentID
    self.bodyMarkdown = bodyMarkdown
    self.attachments = attachments
    self.status = status
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.repositoryPath = repositoryPath
    self.repositorySHA = repositorySHA
    self.repositoryImportFingerprint = repositoryImportFingerprint
    self.reusedFromSourceSnapshot = reusedFromSourceSnapshot
    self.softwareGuideID = softwareGuideID
  }

  public var isPrivate: Bool {
    visibility == .private
  }

  /// Stable content identity for fields controlled by repository Markdown.
  /// Runtime identifiers, timestamps and remote SHAs are excluded so repeated
  /// imports of the same document remain a no-op.
  public var repositoryContentFingerprint: String {
    let coverRepositoryPath = coverAttachmentID.flatMap { coverID in
      attachments.first(where: { $0.id == coverID })?.repositoryPath.normalizedRelativePath()
    }
    let snapshot = RepositoryContentFingerprintSnapshot(
      title: title,
      date: date,
      slug: slug,
      tags: tags,
      categories: categories,
      authors: authors,
      draft: draft,
      visibility: visibility,
      summary: summary,
      coverRepositoryPath: coverRepositoryPath,
      bodyMarkdown: bodyMarkdown,
      attachments: attachments
        .map(RepositoryAttachmentFingerprintSnapshot.init)
        .sorted { lhs, rhs in
          if lhs.repositoryPath == rhs.repositoryPath {
            return lhs.relativePublishPath < rhs.relativePublishPath
          }
          return lhs.repositoryPath < rhs.repositoryPath
        },
      status: status
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    let data = (try? encoder.encode(snapshot)) ?? Data()
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public mutating func touch() {
    updatedAt = Date()
  }

  public static func empty(profile: SiteProfile) -> ArticleDraft {
    let now = Date()
    return ArticleDraft(
      siteProfileID: profile.id,
      title: "未命名文章",
      date: now,
      slug: SlugService.fallbackSlug(date: now),
      tags: profile.defaultTags,
      categories: profile.defaultCategories,
      authors: profile.defaultAuthor.nilIfEmpty.map { [$0] } ?? [],
      bodyMarkdown: "# 未命名文章\n\n从这里开始写作。\n"
    )
  }

  /// Creates safe, editable guides for a brand-new workbench.
  ///
  /// Every guide remains a draft and has no repository path, so opening the
  /// application for the first time can never publish or overwrite a file.
  public static func samples(
    profile: SiteProfile,
    preferredLanguage: String? = Bundle.main.preferredLocalizations.first
      ?? Locale.preferredLanguages.first,
    now: Date = Date()
  ) -> [ArticleDraft] {
    let language = preferredLanguage?.lowercased() ?? "zh-hans"
    let templates = language.hasPrefix("en") ? englishSampleTemplates : chineseSampleTemplates
    let authors = profile.defaultAuthor.nilIfEmpty.map { [$0] } ?? []

    return templates.enumerated().map { index, template in
      let timestamp = now.addingTimeInterval(-TimeInterval(index * 60))
      return ArticleDraft(
        siteProfileID: profile.id,
        title: template.title,
        date: timestamp,
        slug: template.slug,
        tags: template.tags,
        categories: template.categories,
        authors: authors,
        draft: true,
        summary: template.summary,
        bodyMarkdown: template.bodyMarkdown,
        status: .draft,
        createdAt: timestamp,
        updatedAt: timestamp,
        softwareGuideID: template.id
      )
    }
  }

  private struct SampleTemplate {
    let id: String
    let title: String
    let slug: String
    let tags: [String]
    let categories: [String]
    let summary: String
    let bodyMarkdown: String
  }

  private static let chineseSampleTemplates: [SampleTemplate] = [
    SampleTemplate(
      id: "getting-started",
      title: "开始使用：认识发布工作台",
      slug: "personal-site-publisher-getting-started",
      tags: ["使用指南", "入门"],
      categories: ["指南"],
      summary: "从界面布局和推荐流程开始，快速了解如何在一个工作台里完成写作、检查与发布。",
      bodyMarkdown: """
      # 开始使用：认识发布工作台

      欢迎使用个人网站发布控制台。你正在阅读的几篇“使用指南”都是普通草稿，可以自由修改、复制或移到回收站；它们不会自动发布，也不会写入你的仓库。

      ## 界面从左到右

      - **左侧导航**用于切换写作、资料库、同步、图片和内容健康等工作区。
      - **导航下方的列表**显示当前工作区的文章或资料，选择后才会更新右侧内容。
      - **中央区域**承载编辑器、资料阅读、仓库差异和检查结果，是主要操作区域。
      - **右侧检查器**集中显示文章元数据、检查项、图片和发布相关设置；窗口较窄时会自动收起。

      ## 推荐的第一次使用顺序

      1. 已有网站时，先在“同步”中选择本地仓库并确认站点类型、分支和内容路径。
      2. 还没有网站时，从“建站”选择模板，预览即将创建的文件后再执行。
      3. 回到“写作”，新建或导入文章并补全标题、摘要、slug、标签和分类。
      4. 在“内容健康”处理阻断问题，再查看发布预览。
      5. 优先使用 PR/MR 审阅发布；完成后在“发布记录”检查提交和部署状态。

      ## 先做一次安全练习

      修改本段文字，切换“编辑 / 预览 / 分屏”，再打开右侧检查器看看元数据如何同步。只要文章仍为草稿且没有执行发布动作，仓库就不会发生变化。
      """
    ),
    SampleTemplate(
      id: "writing-preview",
      title: "写作与预览：完成第一篇文章",
      slug: "personal-site-publisher-writing-preview",
      tags: ["使用指南", "Markdown", "写作"],
      categories: ["指南"],
      summary: "从新建草稿、编辑 Markdown 到补全元数据和预览，走完一篇文章的写作流程。",
      bodyMarkdown: """
      # 写作与预览：完成第一篇文章

      ## 1. 新建并命名

      在“写作”页面点击文章列表上方的 **＋**。先填写清晰的标题，再检查自动生成的 slug。slug 会成为文章路径的一部分，发布后尽量不要频繁修改。

      ## 2. 专注编辑正文

      中央编辑器支持标准 Markdown。工具栏可以切换：

      - **编辑**：适合集中输入和使用查找替换、格式化等工具。
      - **预览**：检查标题层级、链接、代码块、表格和图片的最终效果。
      - **分屏**：一边修改，一边核对渲染结果；长文会尽量保持同步滚动。

      应用会自动保存工作台状态。重要改动前后仍建议使用版本历史留下可恢复节点。

      ## 3. 补全发布信息

      在右侧检查器完成摘要、日期、作者、标签、分类、公开范围和封面。摘要应能独立说明文章价值，标签保持少而稳定。

      ## 4. 处理提示再发布

      编辑过程中可以查看行内诊断、文章大纲和写作统计。完成后打开“内容健康”，先修复阻断问题，再决定是继续保留草稿还是进入待发布状态。

      > 小练习：复制这一段，插入一个二级标题、一条链接和一个代码块，然后在分屏模式确认预览结果。
      """
    ),
    SampleTemplate(
      id: "knowledge-library",
      title: "资料库：整理并引用长期资料",
      slug: "personal-site-publisher-knowledge-library",
      tags: ["使用指南", "资料库", "研究"],
      categories: ["指南"],
      summary: "把网页和本地文档整理为可搜索、可引用的长期资料，并在写作时保留来源。",
      bodyMarkdown: """
      # 资料库：整理并引用长期资料

      资料库适合保存研究材料、参考文档和长期笔记。它与文章草稿分开管理，因此你可以先整理来源，再决定哪些内容值得写进文章。

      ## 建立资料

      1. 在“资料库”选择导入入口，添加受支持的本地文档或网页。
      2. 导入前核对标题和来源地址；网页内容应确认版权和引用范围。
      3. 导入后检查章节划分、正文识别和元数据，扫描型 PDF 可按需要使用 OCR。
      4. 使用标签、注释和收藏把资料整理为以后仍能理解的结构。

      ## 搜索与引用

      先用全文搜索定位原文，再查看关联章节或语义结果。把内容带入文章时，优先插入短引用、来源名称和链接，不要复制整篇原文。

      如果启用了 AI，可以让助手基于选中的资料总结或拟定提纲，但仍要回到原文核对事实、日期和上下文。

      ## 保持资料库可靠

      - 为重要资料保留明确来源。
      - 定期处理重复、失效或解析不完整的条目。
      - 批量整理或恢复之前先创建资料库备份。
      - 不要把账号令牌、私人密钥或敏感客户资料导入普通资料库。
      """
    ),
    SampleTemplate(
      id: "safe-publishing",
      title: "安全发布：连接仓库、检查并提交",
      slug: "personal-site-publisher-safe-publishing",
      tags: ["使用指南", "Git", "发布"],
      categories: ["指南"],
      summary: "连接本地或远端仓库，审阅路径和差异，通过发布前检查后再安全提交。",
      bodyMarkdown: """
      # 安全发布：连接仓库、检查并提交

      发布控制台只处理文章发布所需的仓库操作。首次连接时，应把“路径正确”和“差异可审阅”放在速度之前。

      ## 1. 配置站点

      在设置或“同步”页面确认站点类型、本地仓库、远端提供商、仓库名称、目标分支、文章目录和图片目录。访问令牌应保存到系统钥匙串，不要写进文章、仓库或截图。

      ## 2. 检查同步状态

      获取远端变化后，先阅读文件列表和 diff。若同一篇文章在远端已经更新，应先导入、合并或重新确认内容，不要直接覆盖。

      ## 3. 通过发布前检查

      发布预览会列出 Markdown 路径、图片路径、变更摘要以及公开风险。请重点确认：

      - 没有本机绝对路径、令牌、邮箱或其他敏感信息。
      - 标题、slug、摘要、封面和内部链接符合站点规则。
      - 图片源文件存在，并且 alt 文本能说明图片内容。
      - 本次 diff 只包含你准备发布的文件。

      ## 4. 选择提交方式

      日常发布优先创建 PR/MR，让差异保留一次最终审阅机会。只有在仓库权限、分支和变更都非常明确时，才考虑直接提交。

      发布完成后不要只看“请求成功”。继续在发布记录中检查提交、自动化任务、部署状态和最终页面内容。
      """
    ),
    SampleTemplate(
      id: "maintenance-recovery",
      title: "发布之后：图片、维护与版本恢复",
      slug: "personal-site-publisher-maintenance",
      tags: ["使用指南", "图片", "维护"],
      categories: ["指南"],
      summary: "用图片工作台、内容健康、维护报告和版本历史保持网站长期清晰、稳定、可恢复。",
      bodyMarkdown: """
      # 发布之后：图片、维护与版本恢复

      一个可靠的网站需要持续维护，而不只是完成一次发布。

      ## 图片

      在“图片”工作区统一检查附件、封面、尺寸、格式、alt 文本和说明。优化或转换图片前先查看影响范围；不要用压缩后的临时文件覆盖唯一原图。

      ## 内容健康

      发布前后都可以运行内容健康检查，重点关注空标题、重复 slug、无效链接、缺失图片、公开风险和不完整元数据。先解决错误，再评估警告是否适用于当前文章。

      ## 日常维护

      维护报告可帮助整理旧文章、标签、发布时间和站内链接。每次只处理一个边界清楚的小批次，并在执行写入前阅读预览。

      ## 恢复与追踪

      - 使用文章版本历史比较改动，必要时恢复正文。
      - 误删文章先到回收站恢复，不要立即手动删除仓库文件。
      - 在发布记录中保存提交、PR/MR 和部署结果，出现问题时据此定位。
      - 定期备份工作台和资料库；备份验证通过后再清理旧副本。

      当你已经熟悉这些流程，可以删除这组示例文章，或把它们改成自己的发布操作手册。
      """
    ),
  ]

  private static let englishSampleTemplates: [SampleTemplate] = [
    SampleTemplate(
      id: "getting-started",
      title: "Getting Started: Meet Your Publishing Workbench",
      slug: "personal-site-publisher-getting-started",
      tags: ["Guide", "Getting Started"],
      categories: ["Guides"],
      summary: "Learn the workspace layout and the recommended path from writing and review to a safe release.",
      bodyMarkdown: """
      # Getting Started: Meet Your Publishing Workbench

      Welcome to Personal Site Publisher. These “Guide” articles are ordinary drafts: edit, duplicate, or move them to the recycle bin whenever you like. They are never published automatically and do not write to your repository on their own.

      ## Read the workspace from left to right

      - **Navigation on the left** switches between Writing, Library, Sync, Images, and Content Health.
      - **The list below navigation** shows articles or sources for the current workspace. Selecting an item updates the working area.
      - **The center** contains the editor, source reader, repository diff, or check results.
      - **The inspector on the right** groups metadata, checks, images, and release settings. It collapses automatically when the window becomes narrow.

      ## A good first-use sequence

      1. If you already have a site, open Sync and choose its local repository, site type, branch, and content paths.
      2. If you need a new site, open Site Starter, choose a template, and review every file before creating it.
      3. Return to Writing, create or import an article, and complete its title, summary, slug, tags, and category.
      4. Resolve blocking issues in Content Health, then review the release preview.
      5. Prefer a pull or merge request for review, and verify the commit and deployment in Release History.

      ## Try a safe exercise

      Edit this paragraph, switch between Edit, Preview, and Split, then open the inspector to see metadata update. As long as the article remains a draft and you do not run a publish action, your repository stays unchanged.
      """
    ),
    SampleTemplate(
      id: "writing-preview",
      title: "Writing and Preview: Finish Your First Article",
      slug: "personal-site-publisher-writing-preview",
      tags: ["Guide", "Markdown", "Writing"],
      categories: ["Guides"],
      summary: "Create a draft, write in Markdown, complete its metadata, and verify the rendered result before release.",
      bodyMarkdown: """
      # Writing and Preview: Finish Your First Article

      ## 1. Create and name the draft

      On the Writing page, click **＋** above the article list. Start with a clear title, then review the generated slug. The slug becomes part of the article path, so avoid changing it frequently after publication.

      ## 2. Work in the editor

      The center editor supports standard Markdown. Use the toolbar to switch between:

      - **Edit** for focused typing, find and replace, and formatting tools.
      - **Preview** to check headings, links, code blocks, tables, and images.
      - **Split** to edit beside the rendered result; long documents keep the two panes synchronized where possible.

      The app autosaves the workbench. For important revisions, keep a version-history checkpoint so the change remains easy to recover.

      ## 3. Complete publishing metadata

      Use the inspector to fill in the summary, date, author, tags, category, visibility, and cover image. A summary should explain the article on its own, while tags should remain few and consistent.

      ## 4. Resolve feedback before release

      While writing, use inline diagnostics, the outline, and writing statistics. When the draft is ready, open Content Health, fix blocking issues, and only then decide whether it should remain a draft or move to Ready.

      > Exercise: duplicate this paragraph, add a level-two heading, a link, and a code block, then confirm the result in Split mode.
      """
    ),
    SampleTemplate(
      id: "knowledge-library",
      title: "Library: Organize and Cite Long-Term Sources",
      slug: "personal-site-publisher-knowledge-library",
      tags: ["Guide", "Library", "Research"],
      categories: ["Guides"],
      summary: "Turn web pages and local documents into searchable, citable sources while preserving where information came from.",
      bodyMarkdown: """
      # Library: Organize and Cite Long-Term Sources

      The Library is for research material, reference documents, and long-lived notes. It is separate from article drafts, so you can organize evidence before deciding what belongs in a post.

      ## Build the library

      1. In Library, use the import entry point to add a supported local document or web page.
      2. Review the title and source URL before import, and respect copyright and quotation limits for web content.
      3. After import, inspect chapter boundaries, extracted text, and metadata. Use OCR only when a scanned PDF needs it.
      4. Add tags, annotations, and favorites that will still make sense months later.

      ## Search and cite

      Begin with full-text search, then inspect related chapters or semantic results. When moving information into an article, prefer a short quotation, source name, and link instead of copying an entire document.

      If AI is enabled, it can summarize selected material or draft an outline, but you should still verify facts, dates, and context against the original source.

      ## Keep the library reliable

      - Preserve a clear source for important material.
      - Review duplicates, broken sources, and incomplete extraction regularly.
      - Create a library backup before large cleanup or restore operations.
      - Never import account tokens, private keys, or sensitive client material into a normal library.
      """
    ),
    SampleTemplate(
      id: "safe-publishing",
      title: "Safe Publishing: Connect, Review, and Commit",
      slug: "personal-site-publisher-safe-publishing",
      tags: ["Guide", "Git", "Publishing"],
      categories: ["Guides"],
      summary: "Connect a local or remote repository, review paths and diffs, pass preflight checks, and publish deliberately.",
      bodyMarkdown: """
      # Safe Publishing: Connect, Review, and Commit

      Personal Site Publisher handles the repository operations needed for article releases. On the first connection, prioritize correct paths and reviewable changes over speed.

      ## 1. Configure the site

      In Settings or Sync, confirm the site type, local repository, remote provider, repository name, target branch, content path, and image path. Store access tokens in the system Keychain—never in an article, repository, or screenshot.

      ## 2. Review synchronization

      After fetching remote changes, read the file list and diff. If the same article changed upstream, import, merge, or review it again instead of overwriting it directly.

      ## 3. Pass preflight

      The release preview lists Markdown and image paths, a change summary, and public-exposure risks. Confirm that:

      - No local absolute path, token, email address, or sensitive value is exposed.
      - The title, slug, summary, cover, and internal links follow site rules.
      - Image source files exist and alt text describes their content.
      - The diff contains only the files intended for this release.

      ## 4. Choose a release method

      Prefer a pull or merge request for routine publishing so every diff gets a final review. Consider a direct commit only when permissions, branch, and changes are completely clear.

      A successful request is not the end: use Release History to verify the commit, automation run, deployment status, and final page content.
      """
    ),
    SampleTemplate(
      id: "maintenance-recovery",
      title: "After Publishing: Images, Maintenance, and Recovery",
      slug: "personal-site-publisher-maintenance",
      tags: ["Guide", "Images", "Maintenance"],
      categories: ["Guides"],
      summary: "Use image tools, content checks, maintenance reports, and version history to keep the site clear and recoverable.",
      bodyMarkdown: """
      # After Publishing: Images, Maintenance, and Recovery

      A dependable site needs ongoing care, not just a successful first release.

      ## Images

      Use Images to review attachments, covers, dimensions, formats, alt text, and captions. Check the affected files before optimization or conversion, and never replace your only original with a temporary compressed copy.

      ## Content Health

      Run Content Health before and after release. Pay particular attention to empty titles, duplicate slugs, broken links, missing images, public-exposure risks, and incomplete metadata. Fix errors first, then decide whether each warning applies.

      ## Routine maintenance

      Maintenance reports help review older posts, tags, publishing dates, and internal links. Work in small, clearly scoped batches and read every preview before a write operation.

      ## Recovery and traceability

      - Compare article versions and restore content when necessary.
      - Recover accidental deletions from the recycle bin before touching repository files manually.
      - Keep commit, pull/merge request, and deployment outcomes in Release History for diagnosis.
      - Back up the workbench and Library regularly, and verify a backup before deleting older copies.

      Once these workflows feel familiar, delete the sample articles or adapt them into your own publishing runbook.
      """
    ),
  ]
}

private struct RepositoryContentFingerprintSnapshot: Encodable {
  var title: String
  var date: Date
  var slug: String
  var tags: [String]
  var categories: [String]
  var authors: [String]
  var draft: Bool
  var visibility: ArticleVisibility
  var summary: String
  var coverRepositoryPath: String?
  var bodyMarkdown: String
  var attachments: [RepositoryAttachmentFingerprintSnapshot]
  var status: DraftStatus
}

private struct RepositoryAttachmentFingerprintSnapshot: Encodable {
  var originalFilename: String
  var relativePublishPath: String
  var repositoryPath: String
  var altText: String
  var caption: String

  init(_ attachment: DraftAttachment) {
    originalFilename = attachment.originalFilename
    relativePublishPath = attachment.relativePublishPath.normalizedRelativePath()
    repositoryPath = attachment.repositoryPath.normalizedRelativePath()
    altText = attachment.altText
    caption = attachment.caption
  }
}
