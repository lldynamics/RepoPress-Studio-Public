import PublishingWorkbenchCore
import SwiftUI

struct AIWritingStyleSection: View {
  let siteProfileID: UUID
  let presetBinding: Binding<AIWritingStylePreset>
  let presetDisplayName: String
  let toneText: Binding<String>
  let audienceText: Binding<String>
  let summaryGuidanceText: Binding<String>
  let tagGuidanceText: Binding<String>
  let seoGuidanceText: Binding<String>
  let preferredTerminologyText: Binding<String>
  let avoidedExpressionsText: Binding<String>
  let exemplarArticleIDs: Binding<Set<UUID>>
  let eligibleArticles: [ArticleDraft]
  let initialPreview: AIWritingStyleProfilePreview?
  let isExtracting: Bool
  let generatePreview: (Set<UUID>) async -> AIWritingStyleProfilePreview?
  let applyPreview: (AIWritingStyleProfilePreview) -> Bool
  let discardPreview: () -> Void
  let currentActionMessage: () -> String?

  @State private var showsCustomRules = false
  @State private var preview: AIWritingStyleProfilePreview?
  @State private var articleQuery = ""
  @State private var extractionTask: Task<Void, Never>?
  @State private var extractionRequestID = UUID()
  @State private var styleMessage: String?

  var body: some View {
    Group {
      Section("行内 AI 续写") {
        Text("在编辑器正文中按 Option + 反斜杠主动请求续写；生成后按 Tab 采纳，按 Esc 丢弃。停顿、输入和移动光标都不会自动发送请求。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Section("个人写作范例") {
        Text("已选择 \(exemplarArticleIDs.wrappedValue.count) / 最多 4 篇")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("只可选择当前站点的公开文章。仅发送所选范例，提炼结果经你确认后保存。")
          .font(.callout)
          .foregroundStyle(.secondary)

        if eligibleArticles.isEmpty {
          Text("当前站点没有可作为范例的公开正文文章。")
            .foregroundStyle(.secondary)
        } else {
          TextField("搜索公开文章", text: $articleQuery)
            .accessibilityLabel("搜索公开文章")
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
              ForEach(filteredArticles) { article in
                Toggle(isOn: selectedArticleBinding(article.id)) {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(
                      article.title.trimmedForPublishing.nilIfEmpty ?? String(localized: "未命名文章"))
                    Text("公开 · \(article.wordCount) 字")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
          .frame(maxHeight: 220)
        }

        Button("用所选文章提炼风格", action: beginExtraction)
          .disabled(
            exemplarArticleIDs.wrappedValue.isEmpty || isExtracting || extractionTask != nil
          )
          .accessibilityIdentifier("settings-ai-writing-style-extract")

        if isExtracting || extractionTask != nil {
          ProgressView("正在准备并提炼公开范例…")
        }
        if let styleMessage {
          Text(styleMessage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }

      if let preview {
        Section("提炼结果预览") {
          Text("检查并编辑后才会保存到当前站点。")
            .font(.callout)
            .foregroundStyle(.secondary)
          if preview.sourceWasTruncated {
            Text("范例内容已按安全长度截取。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          styleEditors(for: previewStyleBinding)
          HStack {
            Button("丢弃预览") {
              self.preview = nil
              discardPreview()
            }
            Button("应用到当前站点") {
              guard let currentPreview = self.preview else { return }
              if applyPreview(currentPreview) {
                self.preview = nil
                styleMessage = currentActionMessage()
              } else {
                styleMessage = currentActionMessage() ?? String(localized: "写作风格预览无法应用，请重新提炼后再试。")
              }
            }
            .workbenchProminentActionStyle()
            .accessibilityIdentifier("settings-ai-writing-style-apply-preview")
          }
        }
      }

      Section("写作风格") {
        VStack(alignment: .leading, spacing: 6) {
          Text("场景模板：")
            .font(.workbenchMetadata)
            .foregroundStyle(.secondary)
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(AIWritingStylePreset.allCases.filter { $0 != .custom }) { preset in
                Button {
                  presetBinding.wrappedValue = preset
                } label: {
                  Text(preset.localizedDisplayName)
                    .font(.caption.weight(presetBinding.wrappedValue == preset ? .bold : .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                      presetBinding.wrappedValue == preset
                        ? WorkbenchTheme.brand.opacity(0.15)
                        : Color.primary.opacity(0.06),
                      in: RoundedRectangle(cornerRadius: 6)
                    )
                    .foregroundStyle(
                      presetBinding.wrappedValue == preset ? WorkbenchTheme.brand : Color.primary)
                }
                .buttonStyle(.plain)
              }
            }
          }
        }
        .padding(.vertical, 2)

        Picker("预设", selection: presetBinding) {
          ForEach(AIWritingStylePreset.allCases) { preset in
            Text(preset.localizedDisplayName).tag(preset)
          }
        }
        .accessibilityLabel("AI 写作风格预设")
        .accessibilityValue(presetDisplayName)

        DisclosureGroup(String(localized: "自定义写作规则"), isExpanded: $showsCustomRules) {
          commonRulePills
          styleEditors(
            toneText: toneText,
            audienceText: audienceText,
            summaryGuidanceText: summaryGuidanceText,
            tagGuidanceText: tagGuidanceText,
            seoGuidanceText: seoGuidanceText,
            preferredTerminologyText: preferredTerminologyText,
            avoidedExpressionsText: avoidedExpressionsText
          )
          Text("这些规则和术语只会随当前站点进入 AI 聊天、元数据建议、发布检查、选区编辑和图片文案建议。")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
    .onAppear {
      if preview == nil, initialPreview?.profileID == siteProfileID { preview = initialPreview }
    }
    .onChange(of: siteProfileID) { _, profileID in
      extractionRequestID = UUID()
      extractionTask?.cancel()
      extractionTask = nil
      styleMessage = nil
      preview = initialPreview?.profileID == profileID ? initialPreview : nil
    }
    .onDisappear {
      extractionRequestID = UUID()
      extractionTask?.cancel()
      extractionTask = nil
    }
  }

  private var filteredArticles: [ArticleDraft] {
    let query = articleQuery.trimmedForPublishing
    guard !query.isEmpty else { return eligibleArticles }
    return eligibleArticles.filter {
      $0.title.localizedCaseInsensitiveContains(query)
        || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
    }
  }

  private func beginExtraction() {
    let profileID = siteProfileID
    let selected = exemplarArticleIDs.wrappedValue
    extractionTask?.cancel()
    let requestID = UUID()
    extractionRequestID = requestID
    styleMessage = nil
    extractionTask = Task { @MainActor in
      guard !Task.isCancelled, extractionRequestID == requestID, siteProfileID == profileID else {
        return
      }
      defer {
        if extractionRequestID == requestID { extractionTask = nil }
      }
      let result = await generatePreview(selected)
      guard !Task.isCancelled, extractionRequestID == requestID, siteProfileID == profileID else {
        return
      }
      if let result, result.profileID == profileID {
        preview = result
      }
    }
  }

  private var commonRulePills: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(String(localized: "常用语气预设："))
        .font(.workbenchMetadata)
        .foregroundStyle(.secondary)
      HStack(spacing: 6) {
        ForEach(
          [
            String(localized: "专业严谨"),
            String(localized: "极简干货"),
            String(localized: "幽默风趣"),
            String(localized: "亲切随笔"),
          ], id: \.self
        ) { pill in
          Button(pill) { append(pill, to: toneText) }.buttonStyle(.bordered)
        }
      }
      Text(String(localized: "常用读者预设："))
        .font(.workbenchMetadata)
        .foregroundStyle(.secondary)
      HStack(spacing: 6) {
        ForEach(
          [
            String(localized: "开发者与程序员"),
            String(localized: "技术小白与初学者"),
            String(localized: "独立博主与创作者"),
          ], id: \.self
        ) { pill in
          Button(pill) { append(pill, to: audienceText) }.buttonStyle(.bordered)
        }
      }
    }
  }

  private func append(_ value: String, to binding: Binding<String>) {
    guard !binding.wrappedValue.contains(value) else { return }
    binding.wrappedValue = binding.wrappedValue.isEmpty ? value : binding.wrappedValue + "，" + value
  }

  private func selectedArticleBinding(_ id: UUID) -> Binding<Bool> {
    Binding(
      get: { exemplarArticleIDs.wrappedValue.contains(id) },
      set: { selected in
        var ids = exemplarArticleIDs.wrappedValue
        if selected {
          guard ids.count < AIWritingStyleConfig.maximumExemplarCount else { return }
          ids.insert(id)
        } else {
          ids.remove(id)
        }
        exemplarArticleIDs.wrappedValue = ids
      }
    )
  }

  private var previewStyleBinding: Binding<AIWritingStyleConfig> {
    Binding(
      get: { preview?.style ?? .default },
      set: { style in
        guard let preview else { return }
        self.preview = AIWritingStyleProfilePreview(
          id: preview.id,
          profileID: preview.profileID,
          exemplarArticleIDs: preview.exemplarArticleIDs,
          style: style,
          baselineStyle: preview.baselineStyle,
          sourceFingerprint: preview.sourceFingerprint,
          sourceWasTruncated: preview.sourceWasTruncated
        )
      }
    )
  }

  @ViewBuilder
  private func styleEditors(for style: Binding<AIWritingStyleConfig>) -> some View {
    styleEditors(
      toneText: style.text(\.tone),
      audienceText: style.text(\.audience),
      summaryGuidanceText: style.text(\.summaryGuidance),
      tagGuidanceText: style.text(\.tagGuidance),
      seoGuidanceText: style.text(\.seoGuidance),
      preferredTerminologyText: style.terminologyText(\.preferredTerminology),
      avoidedExpressionsText: style.terminologyText(\.avoidedExpressions)
    )
  }

  @ViewBuilder
  private func styleEditors(
    toneText: Binding<String>,
    audienceText: Binding<String>,
    summaryGuidanceText: Binding<String>,
    tagGuidanceText: Binding<String>,
    seoGuidanceText: Binding<String>,
    preferredTerminologyText: Binding<String>,
    avoidedExpressionsText: Binding<String>
  ) -> some View {
    AIWritingStyleEditor(title: "语气", text: toneText, accessibilityValue: toneText.wrappedValue)
    AIWritingStyleEditor(
      title: "目标读者", text: audienceText, accessibilityValue: audienceText.wrappedValue)
    AIWritingStyleEditor(
      title: "摘要规则", text: summaryGuidanceText, accessibilityValue: summaryGuidanceText.wrappedValue
    )
    AIWritingStyleEditor(
      title: "标签规则", text: tagGuidanceText, accessibilityValue: tagGuidanceText.wrappedValue)
    AIWritingStyleEditor(
      title: "SEO 检查重点", text: seoGuidanceText, accessibilityValue: seoGuidanceText.wrappedValue)
    AIWritingStyleEditor(
      title: "优先术语（每行一个）", text: preferredTerminologyText,
      accessibilityValue: preferredTerminologyText.wrappedValue)
    AIWritingStyleEditor(
      title: "避免表达（每行一个）", text: avoidedExpressionsText,
      accessibilityValue: avoidedExpressionsText.wrappedValue)
  }
}

extension Binding where Value == AIWritingStyleConfig {
  fileprivate func text(_ keyPath: WritableKeyPath<AIWritingStyleConfig, String> & Sendable)
    -> Binding<String>
  {
    Binding<String>(
      get: { wrappedValue[keyPath: keyPath] },
      set: { value in
        var style = wrappedValue
        style[keyPath: keyPath] = value
        style.preset = .custom
        wrappedValue = style
      }
    )
  }

  fileprivate func terminologyText(
    _ keyPath: WritableKeyPath<AIWritingStyleConfig, [String]> & Sendable
  )
    -> Binding<String>
  {
    Binding<String>(
      get: { wrappedValue[keyPath: keyPath].joined(separator: "\n") },
      set: { value in
        var style = wrappedValue
        style[keyPath: keyPath] = value.components(separatedBy: .newlines)
        style.preset = .custom
        wrappedValue = style
      }
    )
  }
}
