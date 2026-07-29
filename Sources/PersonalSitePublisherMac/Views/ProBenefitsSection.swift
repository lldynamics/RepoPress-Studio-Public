import PublishingWorkbenchCore
import SwiftUI

struct ProBenefitsSection: View {
  var body: some View {
    Section("解锁全部 Pro 终身权益") {
      VStack(alignment: .leading, spacing: 10) {
        Label("全自动线上发布与 Git 库同步", systemImage: "paperplane.fill")
          .font(.body.weight(.medium))
        Label("多仓库与 Hexo / Hugo / Astro 建站框架配置", systemImage: "folder.fill.badge.gearshape")
          .font(.body.weight(.medium))
        Label("无限制素材与文章批量导出", systemImage: "square.and.arrow.up.on.square.fill")
          .font(.body.weight(.medium))
        Label("全库 SEO 诊断与链接死链一键清理", systemImage: "sparkles.tv")
          .font(.body.weight(.medium))
      }
      .foregroundStyle(.primary)
      .padding(.vertical, 4)

      Text("AI 写作辅助与自定义 API 对所有用户开放；由你配置服务商，应用不按次数收费，也不要求 Pro。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
