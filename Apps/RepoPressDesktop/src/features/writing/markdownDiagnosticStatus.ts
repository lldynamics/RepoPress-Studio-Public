import type { MarkdownDiagnosticsSession } from "./useMarkdownDiagnostics";

export function markdownDiagnosticStatusMessage(status: MarkdownDiagnosticsSession["status"]): string {
  switch (status) {
    case "pending": return "正在检查长文…";
    case "cancelled": return "写作检查已取消，尚无检查结果。";
    case "unavailable": return "后台检查不可用，尚无检查结果。";
    case "error": return "写作检查失败或超时，请重试。";
    case "too-large": return "文稿或链接索引超出本地检查上限，尚未检查。";
    case "idle": return "尚未检查当前文稿。";
    case "ready": return "本地写作检查已完成。";
  }
}
