import PublishingCoreSupport
import PublishingWorkbenchCore
import SwiftUI

struct TranslationCreationSection: View {
  let draft: ArticleDraft
  let store: WorkbenchStore
  @Environment(\.workspaceWindowSession) private var windowSession
  @State private var isPresented = false

  var body: some View {
    InspectorSection("多语言版本") {
      Button {
        isPresented = true
      } label: {
        Label("创建译文版本…", systemImage: "character.book.closed")
      }
      .disabled(draft.bodyMarkdown.trimmedForPublishing.isEmpty)
      .accessibilityLabel("创建译文版本")
      .accessibilityIdentifier("create-translation-version")
      .help("选择目标语言，审阅翻译计划后创建独立草稿。")
    }
    .sheet(isPresented: $isPresented) {
      TranslationCreationSheet(sourceDraftID: draft.id, store: store) { draftID in
        windowSession?.selectContext(section: .writing, draftID: draftID) { section, selectedID in
          store.selectSection(section)
          store.selectDraft(selectedID)
        }
      }
    }
  }
}

private struct TranslationCreationSheet: View {
  let sourceDraftID: UUID
  @ObservedObject var store: WorkbenchStore
  let onCreated: (UUID) -> Void
  @ObservedObject private var ai: WorkbenchAIFeatureFacade
  @State private var languageCode = "en"
  @State private var preview: AITranslationDraftPlan?
  @State private var previewIssue: String?
  @State private var plan: AITranslationDraftPlan?
  @State private var message: String?
  @State private var generationTask: Task<Void, Never>?
  @State private var ownerToken: UUID?
  @Environment(\.dismiss) private var dismiss

  init(sourceDraftID: UUID, store: WorkbenchStore, onCreated: @escaping (UUID) -> Void) {
    self.sourceDraftID = sourceDraftID
    self.store = store
    self.onCreated = onCreated
    _ai = ObservedObject(wrappedValue: store.ai)
  }

  private var source: ArticleDraft? {
    store.drafts.first { $0.id == sourceDraftID }
  }

  private var target: AIPublishingChatTranslationTarget {
    AIPublishingChatTranslationDraftService.supportedTargets.first {
      $0.languageCode == languageCode
    } ?? AIPublishingChatTranslationDraftService.supportedTargets[0]
  }

  private var displayedPlan: AITranslationDraftPlan? { plan ?? preview }
  private var issue: String? {
    displayedPlan.flatMap { ai.translationCreationIssue(for: $0) } ?? previewIssue
  }
  private var isGenerating: Bool { ownerToken != nil }

  var body: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.content) {
      Text("创建译文版本")
        .font(.title2.weight(.semibold))
      Text("选择目标语言，生成后审阅标题、摘要与全文，再确认创建新草稿。")
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Picker("目标语言", selection: $languageCode) {
        ForEach(AIPublishingChatTranslationDraftService.supportedTargets, id: \.languageCode) {
          target in
          Text(target.workbenchLocalizedDisplayName).tag(target.languageCode)
        }
      }
      .disabled(isGenerating)
      .accessibilityLabel("译文目标语言")
      .accessibilityIdentifier("translation-target-language")
      .onChange(of: languageCode) { _, _ in
        plan = nil
        message = nil
        refreshPreview()
      }

      if let source, let displayedPlan {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
          Text("目标路径")
            .font(.headline)
          Text(store.profile(for: source).markdownPath(for: displayedPlan.translatedDraft))
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .accessibilityLabel("译文目标路径")
            .accessibilityIdentifier("translation-destination-path")
          if plan == nil {
            Text("生成后会再次显示最终路径；译文默认保持草稿状态。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if store.profile(for: source).siteKind == .hugo, source.translationKey == nil {
            Text("确认创建时会为原稿和译文保存相同的 Hugo 翻译关联键。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      if let issue {
        Label(issue, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("translation-creation-conflict")
      }
      if let message {
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let plan {
        translationReview(plan.translatedDraft)
      } else if isGenerating {
        ProgressView("正在生成译文计划…")
          .accessibilityLabel("正在生成译文计划")
      } else {
        Text("全文会按当前 AI 配置发送，沿用已有的数据发送授权。取消不会创建文章。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack(spacing: WorkbenchSpacing.control) {
        Button("取消") {
          cancelGeneration()
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("取消创建译文")
        Spacer()
        if plan != nil {
          Button("重新生成") { generate() }
            .disabled(isGenerating || ai.isChatRunning || issue != nil)
            .accessibilityLabel("重新生成译文计划")
        } else {
          Button("生成翻译计划") { generate() }
            .disabled(source == nil || preview == nil || issue != nil || ai.isChatRunning)
            .accessibilityLabel("生成翻译计划")
            .accessibilityIdentifier("generate-translation-plan")
        }
        if let plan {
          Button("确认创建并打开") {
            if let created = ai.createLinkedTranslationDraft(from: plan) {
              onCreated(created.id)
              dismiss()
            } else {
              message = ai.chatMessage
            }
          }
          .workbenchProminentActionStyle()
          .disabled(isGenerating || issue != nil)
          .keyboardShortcut(.defaultAction)
          .accessibilityLabel("确认创建并打开译文草稿")
          .accessibilityIdentifier("confirm-translation-creation")
        }
      }
    }
    .padding(WorkbenchSpacing.page)
    .frame(minWidth: 480, idealWidth: 620, maxWidth: 760, minHeight: 320, maxHeight: 760)
    .onAppear(perform: refreshPreview)
    .onChange(of: source) { _, _ in refreshPreview() }
    .onDisappear(perform: cancelGeneration)
  }

  private func refreshPreview() {
    preview = nil
    previewIssue = nil
    guard let source else {
      previewIssue = String(localized: "找不到翻译计划对应的原稿。")
      return
    }
    do {
      preview = try ai.translationCreationPreview(source: source, target: target)
    } catch {
      previewIssue = error.localizedDescription
    }
  }

  private func translationReview(_ translated: ArticleDraft) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: WorkbenchSpacing.card) {
        Text(translated.title)
          .font(.headline)
          .accessibilityLabel("译文标题")
        if !translated.summary.isEmpty {
          Text(translated.summary)
            .foregroundStyle(.secondary)
            .accessibilityLabel("译文摘要")
        }
        Text(translated.bodyMarkdown)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("译文全文预览")
      }
      .textSelection(.enabled)
      .padding(WorkbenchSpacing.card)
    }
    .frame(minHeight: 160, idealHeight: 320, maxHeight: 420)
    .background(
      Color.primary.opacity(0.035),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.panel)
    )
  }

  private func generate() {
    guard !isGenerating else { return }
    let token = UUID()
    let selectedTarget = target
    plan = nil
    message = nil
    ownerToken = token
    generationTask = Task { @MainActor in
      let result = await ai.generateTranslationDraftPlan(
        sourceDraftID: sourceDraftID, target: selectedTarget, ownerToken: token)
      guard !Task.isCancelled, ownerToken == token else { return }
      plan = result
      if result == nil {
        message = ai.chatMessage ?? String(localized: "未能生成译文计划，请检查 AI 配置后重试。")
      }
      ownerToken = nil
      generationTask = nil
    }
  }

  private func cancelGeneration() {
    generationTask?.cancel()
    generationTask = nil
    if let ownerToken {
      ai.cancelChatReply(expectedOwnerToken: ownerToken)
    }
    ownerToken = nil
  }
}
