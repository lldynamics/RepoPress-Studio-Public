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
          informationHierarchy
          emptyStates
          unifiedStates
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
        Text("工具栏与强调表面")
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

    private var informationHierarchy: some View {
      WorkbenchSectionGroup(
        "扁平信息层级",
        detail: "普通信息使用列表行和分隔线；只突出异常、选中项和主要动作。"
      ) {
        WorkbenchInformationRow(
          title: "本地仓库",
          detail: Text("站点目录已连接"),
          systemImage: "folder"
        )
        Divider()
        WorkbenchInformationRow(
          title: "发布规则缺失",
          detail: Text("请先补充文章路径规则。"),
          systemImage: "exclamationmark.triangle",
          emphasis: .warning
        )
        Divider()
        WorkbenchInformationRow(
          title: "当前站点",
          detail: Text("RepoPress 文档站"),
          systemImage: "checkmark.circle",
          emphasis: .selected
        ) {
          Button("继续") {}
            .workbenchProminentActionStyle()
            .controlSize(.small)
        }
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

    private var unifiedStates: some View {
      VStack(alignment: .leading, spacing: WorkbenchSpacing.card) {
        Text("统一状态")
          .font(.workbenchSectionTitle)

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 250), spacing: WorkbenchSpacing.card)],
          spacing: WorkbenchSpacing.card
        ) {
          WorkbenchStateView(
            presentation: WorkbenchStatePresentation(kind: .loading()),
            density: .compactPane,
            detail: "正在读取站点内容…"
          )
          WorkbenchStateView(
            presentation: WorkbenchStatePresentation(kind: .empty),
            density: .compactPane,
            detail: "完成首次操作后会显示在这里。"
          )
          WorkbenchStateView(
            presentation: WorkbenchStatePresentation(kind: .failure(reason: "网络连接已断开。")),
            density: .compactPane,
            detail: "检查网络后重试。",
            actions: WorkbenchStateActions(
              primary: WorkbenchStateAction(
                title: "重试",
                systemImage: "arrow.clockwise",
                action: {}
              )
            )
          )
          WorkbenchStateView(
            presentation: WorkbenchStatePresentation(
              kind: .partialSuccess(detail: "已完成 8 项；2 项需要复核。")
            ),
            density: .compactPane
          )
          WorkbenchStateView(
            presentation: WorkbenchStatePresentation(
              kind: .awaitingConfirmation(detail: "尚未写入，检查后确认继续。")
            ),
            density: .compactPane
          )
          WorkbenchStateView(
            presentation: WorkbenchStatePresentation(
              kind: .unavailable(reason: "请先选择站点文件夹。")
            ),
            density: .compactPane
          )
        }
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

  private struct WorkbenchThemeAndCardPreview: View {
    var body: some View {
      VStack(alignment: .leading, spacing: WorkbenchSpacing.content) {
        Text("主题色板与卡片")
          .font(.workbenchPageTitle)

        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 120), spacing: WorkbenchSpacing.card)],
          spacing: WorkbenchSpacing.card
        ) {
          previewSwatch("主色", color: WorkbenchTheme.primary)
          previewSwatch("成功", color: WorkbenchTheme.success)
          previewSwatch("警告", color: WorkbenchTheme.warning)
          previewSwatch("风险", color: WorkbenchTheme.risk)
        }

        PublishDrawerCard(title: "发布目标", systemImage: "network") {
          Label("GitHub · main", systemImage: "arrow.triangle.branch")
            .font(.workbenchBody)
          Text("检查卡片的材质、内边距和明暗对比。")
            .font(.workbenchSupporting)
            .foregroundStyle(.secondary)
        }
      }
      .padding(WorkbenchSpacing.content)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func previewSwatch(_ title: String, color: Color) -> some View {
      HStack(spacing: WorkbenchSpacing.control) {
        Circle()
          .fill(color)
          .frame(width: 18, height: 18)
        Text(title)
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

  #Preview("Theme Palette & Card") {
    WorkbenchThemeAndCardPreview()
      .frame(width: 520, height: 420)
      .preferredColorScheme(.dark)
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

  #Preview("Unified States - Dark Large Text") {
    VStack(spacing: WorkbenchSpacing.card) {
      WorkbenchStateView(
        presentation: WorkbenchStatePresentation(kind: .loading(progress: 0.45)),
        density: .inline,
        detail: "正在检查发布前条件…"
      )
      WorkbenchStateView(
        presentation: WorkbenchStatePresentation(
          kind: .partialSuccess(detail: "已完成可执行项目；其余项目需要处理。")
        ),
        density: .inline
      )
      WorkbenchStateView(
        presentation: WorkbenchStatePresentation(
          kind: .unavailable(reason: "当前配置未提供所需权限。")
        ),
        density: .inline
      )
      WorkbenchStateView(
        presentation: WorkbenchStatePresentation(
          kind: .success(detail: "全部检查项均已完成。")
        ),
        density: .compactPane
      )
      WorkbenchStateView(
        presentation: WorkbenchStatePresentation(
          kind: .failure(
            reason: "服务器返回了较长的诊断信息；请检查连接、凭据和访问权限后重试。"
          )
        ),
        density: .compactPane,
        actions: WorkbenchStateActions(
          primary: WorkbenchStateAction(
            title: "重试",
            systemImage: "arrow.clockwise",
            action: {}
          ),
          secondary: WorkbenchStateAction(
            title: "查看详情",
            systemImage: "doc.text.magnifyingglass",
            action: {}
          )
        )
      )
    }
    .padding(WorkbenchSpacing.page)
    .frame(width: 620)
    .dynamicTypeSize(.accessibility2)
    .preferredColorScheme(.dark)
  }
#endif
