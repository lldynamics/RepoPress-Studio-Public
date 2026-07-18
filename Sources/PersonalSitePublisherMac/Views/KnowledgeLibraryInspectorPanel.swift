import PublishingWorkbenchCore
import SwiftUI

struct KnowledgeLibraryInspectorPanel: View {
  @ObservedObject var knowledge: KnowledgeStore
  let document: KnowledgeDocument
  let activeSearchResult: KnowledgeSearchResult?
  let onEditMetadata: () -> Void
  let onAddAnnotation: () -> Void
  let onAnnotateSearchHit: () -> Void
  let onEditAnnotation: (KnowledgeAnnotation) -> Void
  let onDeleteAnnotation: (UUID) -> Void
  let onOpenSourceHistory: () -> Void
  let onReportContentIssue: () -> Void

  @State private var showsInsights = false
  @State private var showsRelatedContent = true
  @State private var showsQualityActions = false
  @State private var showsAllRelatedContent = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 8) {
          Label("资料检查器", systemImage: "sidebar.trailing")
            .font(.headline)
          Spacer()
          Button(action: onEditMetadata) {
            Image(systemName: "pencil")
          }
          .buttonStyle(.plain)
          .help("编辑元数据")
          .accessibilityLabel("编辑资料元数据")
        }

        VStack(alignment: .leading, spacing: 8) {
          Button(action: onAddAnnotation) {
            Label("添加资料笔记", systemImage: "note.text.badge.plus")
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          if activeSearchResult != nil {
            Button(action: onAnnotateSearchHit) {
              Label("标注当前搜索命中", systemImage: "highlighter")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        .controlSize(.small)

        Divider()

        DisclosureGroup(isExpanded: $showsInsights) {
          KnowledgeDocumentInsightsSection(
            annotations: knowledge.annotations,
            backlinkGroups: knowledge.backlinkGroups,
            onAddAnnotation: onAddAnnotation,
            onEditAnnotation: onEditAnnotation,
            onDeleteAnnotation: onDeleteAnnotation,
            showsHeader: false
          )
          .padding(.top, 8)
        } label: {
          Label(
            "标注与反向链接（\(knowledge.annotations.count + knowledge.backlinkGroups.count)）",
            systemImage: "link.badge.plus"
          )
          .font(.callout.weight(.semibold))
        }

        Divider()

        DisclosureGroup(isExpanded: $showsRelatedContent) {
          KnowledgeRelatedChaptersSection(
            knowledge: knowledge,
            showsHeader: false,
            maximumVisibleRecommendations: showsAllRelatedContent ? nil : 3
          )
            .padding(.top, 8)
          if knowledge.relatedChapters.count > 3 {
            Button(
              showsAllRelatedContent
                ? String(localized: "收起相关内容")
                : String(
                  format: String(localized: "显示全部 %lld 条"),
                  knowledge.relatedChapters.count
                )
            ) {
              showsAllRelatedContent.toggle()
            }
            .buttonStyle(.link)
            .padding(.top, 4)
          }
        } label: {
          HStack {
            Label(relatedTitle, systemImage: "point.3.connected.trianglepath.dotted")
              .font(.callout.weight(.semibold))
            Spacer()
            if knowledge.isLoadingRelatedChapters {
              ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("正在查找\(relatedTitle)")
            } else {
              Text("\(knowledge.relatedChapters.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
        }

        Divider()

        DisclosureGroup(isExpanded: $showsQualityActions) {
          VStack(alignment: .leading, spacing: 9) {
            if document.kind == .webpage {
              Text("如果正文缺失、混入导航、订阅或网页页脚，可以先比较当前正文与重新净化结果，再决定是否创建新版本。")
                .font(.caption)
                .foregroundStyle(.secondary)
              Button("正文质量有问题？") {
                onReportContentIssue()
              }
              .disabled(knowledge.isBusy)
            } else {
              Text("可以查看来源更新和历史版本；已有版本不会被静默覆盖。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button("来源更新与版本历史…", action: onOpenSourceHistory)
              .buttonStyle(.link)
          }
          .padding(.top, 8)
        } label: {
          Label("正文质量与版本", systemImage: "checkmark.shield")
            .font(.callout.weight(.semibold))
        }
      }
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .accessibilityIdentifier("knowledge-library-inspector")
    .onChange(of: document.id) { _, _ in
      showsAllRelatedContent = false
    }
  }

  private var relatedTitle: String {
    document.kind == .book ? "相关章节" : "相关内容"
  }
}
