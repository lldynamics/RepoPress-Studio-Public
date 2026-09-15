import PublishingWorkbenchCore
import SwiftUI

/// Chooses a complete article body before inserting a draft.  Creation is
/// performed only from the explicit Create action, so dismissing the sheet is
/// a safe no-op.
struct WritingDraftTemplatePicker: View {
  let store: WorkbenchStore
  let onCreate: (MarkdownSnippet, Bool, String) -> Bool
  @Environment(\.dismiss) private var dismiss
  @State private var destination: DraftListContentScope = .currentSite
  @State private var selectedTemplateID: String?
  @State private var articleTitle = ""
  @State private var creationError: String?
  @State private var initialProfileID: UUID
  @State private var initialSiteName: String

  init(store: WorkbenchStore, onCreate: @escaping (MarkdownSnippet, Bool, String) -> Bool) {
    self.store = store
    self.onCreate = onCreate
    _initialProfileID = State(initialValue: store.activeProfileID)
    _initialSiteName = State(initialValue: store.activeProfile.name)
  }

  private var templates: [MarkdownSnippet] {
    MarkdownSnippetLibraryService.availableSnippets(
      for: initialProfileID,
      customSnippets: store.customMarkdownSnippets
    )
    .filter { $0.kind == .articleTemplate }
  }

  private var selectedTemplate: MarkdownSnippet? {
    templates.first { $0.id == selectedTemplateID }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("从模板新建文章")
        .font(.title2.weight(.semibold))

      Picker("草稿归属", selection: $destination) {
        Text("当前站点：\(initialSiteName)").tag(DraftListContentScope.currentSite)
        Text("通用草稿").tag(DraftListContentScope.general)
      }
      .pickerStyle(.segmented)

      TextField("文章标题（可稍后修改）", text: $articleTitle)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("新文章标题")
        .accessibilityIdentifier("writing-template-title")

      List(templates, selection: $selectedTemplateID) { template in
        VStack(alignment: .leading, spacing: 4) {
          Label(template.title, systemImage: template.systemImage)
            .font(.headline)
          Text(template.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .tag(Optional(template.id))
      }
      .listStyle(.inset)
      .accessibilityIdentifier("writing-template-picker-list")

      if let selectedTemplate {
        ScrollView {
          Text(selectedTemplate.markdown)
            .font(.caption.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 110)
        .accessibilityLabel("模板正文预览")
      }
      if let creationError {
        Text(creationError).font(.caption).foregroundStyle(WorkbenchTheme.warning)
      }

      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("新建") {
          guard let selectedTemplate else { return }
          guard store.activeProfileID == initialProfileID else {
            creationError = String(localized: "站点已切换，请重新打开模板选择。")
            return
          }
          if onCreate(selectedTemplate, destination == .general, articleTitle) {
            dismiss()
          } else {
            creationError = String(localized: "模板无法创建文章，请检查模板正文后重试。")
          }
        }
        .workbenchProminentActionStyle()
        .disabled(selectedTemplate == nil)
        .accessibilityIdentifier("writing-template-create")
      }
    }
    .padding(20)
    .frame(minWidth: 480, minHeight: 420)
    .onAppear {
      selectedTemplateID = templates.first?.id
    }
    .accessibilityIdentifier("writing-template-picker")
  }
}
