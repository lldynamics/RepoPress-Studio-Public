import PublishingWorkbenchCore
import SwiftUI

/// Article filters share the palette's query; replacement remains a separate
/// preview-and-apply workflow rather than a mode of the search field.
struct WorkspaceCommandPaletteArticleControls: View {
  @Binding var query: String
  @Binding var scope: DraftFullTextSearchScope
  let onBatchReplace: () -> Void
  @AppStorage("draftFullTextSavedQueriesV1") private var savedQueriesStorage = ""

  private var parsedQuery: DraftFullTextSearchQuery { DraftFullTextSearchQuery(query) }
  private var savedQueries: [DraftFullTextSavedQuery] {
    DraftFullTextSavedQueryService.decode(savedQueriesStorage)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Picker("文章范围", selection: $scope) {
          ForEach(DraftFullTextSearchScope.allCases) { candidate in
            Text(candidate.localizedDisplayName).tag(candidate)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("文章范围")
        .accessibilityIdentifier("workspace-command-palette-article-scope")

        savedQueriesMenu
        Spacer(minLength: 8)
        Button(action: onBatchReplace) {
          Label("批量替换", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(scope == .generalDrafts)
        .help(
          scope == .generalDrafts
            ? String(localized: "批量替换暂不支持通用草稿范围，以免扩大到全部站点。")
            : String(localized: "在独立面板预览并替换站点文章正文；不包含通用草稿。")
        )
        .accessibilityLabel("跨文章批量查找替换")
        .accessibilityIdentifier("workspace-command-palette-batch-replace")
      }

      if parsedQuery.invalidFilters.isEmpty {
        Text("支持 title:、tag:、status:、before:、after:、is:private；日期按文章日期。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Label(
          "无法识别的搜索条件：\(parsedQuery.invalidFilters.joined(separator: "、"))",
          systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.warning)
      }
    }
  }

  private var savedQueriesMenu: some View {
    Menu {
      if savedQueries.isEmpty {
        Text("尚未保存查询")
      } else {
        ForEach(savedQueries) { savedQuery in
          Button {
            query = savedQuery.query
            scope = savedQuery.scope
          } label: {
            Text(verbatim: savedQuery.query + " · " + savedQuery.scope.localizedDisplayName)
          }
        }
      }
      Divider()
      Button {
        savedQueriesStorage = DraftFullTextSavedQueryService.encode(
          DraftFullTextSavedQueryService.saving(query: query, scope: scope, in: savedQueries)
        )
      } label: {
        Label("保存当前查询", systemImage: "bookmark")
      }
      .disabled(!parsedQuery.hasCriteria)

      if !savedQueries.isEmpty {
        Menu("删除保存的查询") {
          ForEach(savedQueries) { savedQuery in
            Button(role: .destructive) {
              savedQueriesStorage = DraftFullTextSavedQueryService.encode(
                DraftFullTextSavedQueryService.removing(id: savedQuery.id, from: savedQueries)
              )
            } label: {
              Text(verbatim: savedQuery.query + " · " + savedQuery.scope.localizedDisplayName)
            }
          }
        }
      }
    } label: {
      Label("保存的查询", systemImage: "bookmark")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("保存、载入或删除全文搜索查询")
    .accessibilityLabel("保存的全文搜索查询")
  }
}
