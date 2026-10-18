import PublishingMarkdownCore
import PublishingWorkbenchCore
import SwiftUI

extension MacMarkdownComposerView {
  func resolveDuplicateTitleWarning() async {
    let key = duplicateTitleWarningResolutionKey
    guard !draft.isGeneralDraft else { return }
    let enabled = await key.profile.resolveBodyH1DuplicateWarning(
      repositoryRevision: key.repositoryRevision)
    guard !Task.isCancelled, duplicateTitleWarningResolutionKey == key else { return }
    duplicateTitleWarningResolution = .init(key: key, isEnabled: enabled)
  }

  @ViewBuilder
  var emptyBodyPlaceholder: some View {
    if editorBody.isEmpty, isArticleInformationFolded, frontMatterIssue == nil {
      Text("从这里开始写作。")
        .font(.workbenchBody)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, WorkbenchSpacing.page)
        .padding(.top, WorkbenchSpacing.content)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  var duplicateTitleWarningResolutionKey: MarkdownDuplicateTitleWarningResolution.Key {
    .init(
      draftID: draft.id, profile: activeProfile, repositoryRevision: store.repositoryReportRevision)
  }

  var isArticleInformationFolded: Bool {
    !isArticleInformationExpanded && frontMatterIssue == nil
  }

  /// Shown beside the file path in the title row instead of as a separate
  /// strip above the editor. Front Matter has one explicit disclosure control.
  var articleInformationToggle: MacMarkdownArticleInformationToggle? {
    return MacMarkdownArticleInformationToggle(
      isExpanded: Binding(
        get: { !isArticleInformationFolded },
        set: { isArticleInformationExpanded = $0 }
      ),
      isEnabled: frontMatterIssue == nil
    )
  }

  @ViewBuilder
  var duplicateBodyTitleNotice: some View {
    if MarkdownDuplicateTitleNoticePolicy.shouldShow(
      draft: draft, profile: activeProfile, body: editorBody,
      hasFrontMatterIssue: frontMatterIssue != nil,
      resolvedWarning: duplicateTitleWarningResolution?.key == duplicateTitleWarningResolutionKey
        ? duplicateTitleWarningResolution?.isEnabled : nil)
    {
      let requestedDraftID = draft.id
      let requestedTitle = draft.title
      let noticeLabel = Label("正文首行与文章标题重复。", systemImage: "info.circle")
        .foregroundStyle(.workbenchSecondary)
        .fixedSize(horizontal: false, vertical: true)
      let removeButton = Button("删除正文标题") {
        removeDuplicateBodyTitle(for: requestedDraftID, title: requestedTitle)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(editorEditRequest != nil)
      .help("仅删除正文开头重复的标题，可撤销恢复。")
      .accessibilityIdentifier("markdown-remove-duplicate-body-title")
      let keepButton = Button("保留，不再提示") {
        guard draft.id == requestedDraftID,
          draft.belongs(toSiteProfileID: activeProfile.id)
        else { return }
        store.setH1DuplicateWarning(false, forProfileID: activeProfile.id)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .help("保留正文标题，并关闭此站点的重复标题提示。")
      .accessibilityIdentifier("markdown-keep-duplicate-body-title")
      ViewThatFits(in: .horizontal) {
        HStack(spacing: WorkbenchSpacing.control) {
          noticeLabel
          removeButton
          keepButton
        }
        .fixedSize(horizontal: true, vertical: false)
        VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
          noticeLabel
          HStack(spacing: WorkbenchSpacing.control) {
            removeButton
            keepButton
          }
        }
        .fixedSize(horizontal: true, vertical: false)
        VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
          noticeLabel
          removeButton
          keepButton
        }
      }
      .font(.workbenchMetadata)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, WorkbenchSpacing.content)
      .padding(.vertical, WorkbenchSpacing.icon)
      .background(.quaternary.opacity(0.3))
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("markdown-duplicate-body-title-notice")
      Divider()
    }
  }

  func removeDuplicateBodyTitle(for expectedDraftID: UUID, title expectedTitle: String) {
    guard draft.id == expectedDraftID, draft.title == expectedTitle, editorEditRequest == nil else {
      return
    }
    guard editorSessionState.commandTarget.flushPendingWrites(for: expectedDraftID) else {
      reportDuplicateTitleRemoval(String(localized: "请先完成当前输入，再删除正文标题。"))
      return
    }
    let buffer = store.draftBodyEditorBuffer(for: expectedDraftID)
    guard draft.id == expectedDraftID, draft.title == expectedTitle,
      frontMatterIssue == nil, editorSessionState.invalidFrontMatterBaseBodyMarkdown == nil,
      store.draft(for: expectedDraftID)?.editorMetadataRevision == draft.editorMetadataRevision,
      buffer.bodyMarkdown == editorBody,
      editorSessionState.liveBodyMarkdown == editorBody,
      editorSessionState.liveBodyRevision == buffer.revision,
      let edit = MarkdownDuplicateTitleService.removalEdit(
        in: editorBody, title: expectedTitle, selectedRange: selectedRange
      )
    else {
      reportDuplicateTitleRemoval(String(localized: "文章已变化，正文标题未删除，请检查后重试。"))
      return
    }
    let request = MarkdownTextEditRequest(expectedText: editorBody, edit: edit)
    pendingDuplicateTitleRemoval = MarkdownDuplicateTitleRemovalSnapshot(
      requestID: request.id, draftID: expectedDraftID,
      metadataRevision: draft.editorMetadataRevision, bodyRevision: buffer.revision
    )
    editorEditRequest = request
  }

  var articleInformationEditAdmission: ((MarkdownTextEditRequest) -> Bool)? {
    guard pendingDuplicateTitleRemoval != nil || attachmentInsertionAdmission != nil else {
      return nil
    }
    let duplicateTitleRemoval = pendingDuplicateTitleRemoval
    return { request in
      guard let pending = duplicateTitleRemoval, pending.requestID == request.id else {
        return attachmentInsertionAdmission?(request) ?? true
      }
      // A queued native edit can outlive another window's update or a new
      // unflushed Front Matter edit. Drain and validate again on admission.
      guard pendingDuplicateTitleRemoval?.requestID == request.id,
        editorEditRequest?.id == request.id,
        editorSessionState.commandTarget.flushPendingWrites(for: pending.draftID)
      else { return false }
      return pending.admits(
        draftID: draft.id, metadataRevision: draft.editorMetadataRevision,
        storedMetadataRevision: store.draft(for: pending.draftID)?.editorMetadataRevision,
        buffer: store.draftBodyEditorBuffer(for: pending.draftID),
        expectedBody: request.expectedText,
        hasFrontMatterConflict: frontMatterIssue != nil
          || editorSessionState.invalidFrontMatterBaseBodyMarkdown != nil
      )
    }
  }

  func handleDuplicateTitleRemovalOutcome(_ outcome: MarkdownTextEditRequestOutcome) {
    guard let pending = pendingDuplicateTitleRemoval, pending.requestID == outcome.id else {
      return
    }
    pendingDuplicateTitleRemoval = nil
    guard pending.draftID == draft.id else { return }
    reportDuplicateTitleRemoval(
      outcome.wasApplied
        ? String(localized: "已删除正文开头的重复标题，可撤销恢复。")
        : String(localized: "文章已变化，正文标题未删除，请检查后重试。")
    )
  }

  private func reportDuplicateTitleRemoval(_ message: String) {
    selectionActionMessage = message
    EditorAccessibilityAnnouncementCenter.announce(message)
  }
}

struct MarkdownDuplicateTitleWarningResolution: Equatable {
  struct Key: Hashable {
    let draftID: UUID
    let profile: SiteProfile
    let repositoryRevision: UUID
  }
  let key: Key
  let isEnabled: Bool
}

enum MarkdownDuplicateTitleNoticePolicy {
  static func shouldShow(
    draft: ArticleDraft, profile: SiteProfile, body: String,
    hasFrontMatterIssue: Bool, resolvedWarning: Bool?
  ) -> Bool {
    guard !hasFrontMatterIssue, draft.belongs(toSiteProfileID: profile.id),
      profile.warnsWhenBodyH1DuplicatesTitle != false, resolvedWarning == true
    else { return false }
    return MarkdownDuplicateTitleService.duplicateTitleRange(in: body, title: draft.title) != nil
  }
}

struct MacMarkdownArticleInformationToggle: View {
  @Binding var isExpanded: Bool
  let isEnabled: Bool

  var body: some View {
    Button {
      isExpanded.toggle()
    } label: {
      Label("文章信息", systemImage: isExpanded ? "chevron.down" : "chevron.right")
        .labelStyle(.titleAndIcon)
    }
    .buttonStyle(.plain)
    .font(.workbenchMetadata)
    .foregroundStyle(.workbenchSecondary)
    .disabled(!isEnabled)
    .help(
      isExpanded
        ? String(localized: "编辑文章标题、日期、标签和其他字段。")
        : String(localized: "标题、日期、标签等信息已收起，展开可编辑源码。")
    )
    .accessibilityValue(isExpanded ? String(localized: "已展开") : String(localized: "已收起"))
    .accessibilityIdentifier("markdown-article-information-toggle")
  }
}
