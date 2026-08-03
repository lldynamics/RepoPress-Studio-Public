#if DEBUG
  import SwiftUI

  private struct WorkbenchDesignSystemPreview: View {
    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.spacious) {
          Text("RepoPress Design System")
            .font(.workbenchPageTitle)

          palette
          controls
          emptyStates
          modalSurface
        }
        .workbenchPageLayout(maxWidth: .infinity)
      }
    }

    private var palette: some View {
      VStack(alignment: .leading, spacing: WorkbenchSpacing.card) {
        Text("语义色")
          .font(.workbenchSectionTitle)

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 120), spacing: WorkbenchSpacing.card)],
          spacing: WorkbenchSpacing.card
        ) {
          paletteSwatch("Primary", color: WorkbenchTheme.primary)
          paletteSwatch("Info", color: WorkbenchTheme.info)
          paletteSwatch("Success", color: WorkbenchTheme.success)
          paletteSwatch("Warning", color: WorkbenchTheme.warning)
          paletteSwatch("Risk", color: WorkbenchTheme.risk)
          paletteSwatch("Neutral", color: WorkbenchTheme.neutral)
        }
      }
    }

    private var controls: some View {
      VStack(alignment: .leading, spacing: WorkbenchSpacing.card) {
        Text("工具栏与卡片")
          .font(.workbenchSectionTitle)

        HStack(spacing: WorkbenchSpacing.card) {
          Button {
          } label: {
            Label("资料库", systemImage: "books.vertical")
          }
          .buttonStyle(WorkspaceToolbarIconButtonStyle(isActive: false, showsTitle: true))

          Button {
          } label: {
            Label("写作", systemImage: "square.and.pencil")
          }
          .buttonStyle(WorkspaceToolbarIconButtonStyle(isActive: true, showsTitle: true))
        }

        Text("WorkbenchBackgroundStyle.card")
          .font(.workbenchBody)
          .padding(WorkbenchSpacing.card)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            WorkbenchBackgroundStyle.card,
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
          )
      }
    }

    private var emptyStates: some View {
      VStack(alignment: .leading, spacing: WorkbenchSpacing.card) {
        Text("空态")
          .font(.workbenchSectionTitle)

        HStack(alignment: .top, spacing: WorkbenchSpacing.content) {
          EmptyStateView(
            title: "暂无内容",
            message: "创建第一篇文章后会显示在这里。",
            systemImage: "doc.text",
            density: .compactPane,
            actionTitle: "新建文章",
            action: {}
          )

          GuidedEmptyStateView(
            title: "开始写作",
            message: "选择一种方式建立第一篇内容。",
            systemImage: "square.and.pencil",
            actions: [
              GuidedEmptyStateAction(
                id: "preview-create-draft",
                title: "新建空白文章",
                subtitle: "从一个干净的 Markdown 文档开始。",
                systemImage: "doc.badge.plus",
                action: {}
              )
            ]
          )
        }
        .frame(minHeight: 260)
      }
    }

    private var modalSurface: some View {
      VStack(alignment: .leading, spacing: WorkbenchSpacing.card) {
        Text("Modal surface")
          .font(.workbenchSectionTitle)

        WorkbenchModalSurface {
          VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
            Label("统一弹窗表面", systemImage: "macwindow")
              .font(.workbenchCardTitle)
            Text("用于检查材质、边框与明暗外观。")
              .font(.workbenchSupporting)
              .foregroundStyle(.secondary)
          }
          .padding(WorkbenchSpacing.content)
        }
        .frame(height: 96)
      }
    }

    private func paletteSwatch(_ name: String, color: Color) -> some View {
      HStack(spacing: WorkbenchSpacing.control) {
        Circle()
          .fill(color)
          .frame(width: 18, height: 18)
        Text(name)
          .font(.workbenchMetadata)
      }
      .padding(WorkbenchSpacing.control)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        WorkbenchBackgroundStyle.card,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
    }
  }

  #Preview("Design System - Light") {
    WorkbenchDesignSystemPreview()
      .frame(width: 960, height: 760)
      .preferredColorScheme(.light)
  }

  #Preview("Design System - Dark") {
    WorkbenchDesignSystemPreview()
      .frame(width: 960, height: 760)
      .preferredColorScheme(.dark)
  }

  #Preview("Empty State - Large Text") {
    EmptyStateView(
      title: "没有匹配的文章",
      message: "调整搜索条件，或清除筛选后再试一次。",
      systemImage: "doc.text.magnifyingglass",
      density: .compactPane,
      actionTitle: "清除筛选",
      action: {}
    )
    .frame(width: 520, height: 260)
    .dynamicTypeSize(.accessibility2)
  }
#endif
