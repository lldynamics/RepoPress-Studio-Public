import type { OperationKind, OperationLogEntry } from "../../contracts/activity";

export type OperationCategory = "writing" | "draft" | "image" | "publish" | "knowledge";
export type OperationOutcomeFilter = "all" | "succeeded" | "failed";
export type OperationRepositoryFilter = "all" | "current" | "unlinked";

export const OPERATION_KIND_LABELS: Record<OperationKind, string> = {
  saveDocument: "保存文稿", createDocument: "创建文稿", renameDocument: "重命名文稿", deleteDocument: "删除文稿",
  restoreDraftVersion: "恢复草稿版本", restoreRecycledDraft: "恢复回收草稿", deleteRecycledDraft: "删除回收草稿",
  saveGeneralDraft: "保存通用草稿", transferGeneralDraft: "转移通用草稿", undoGeneralDraftTransfer: "撤销草稿转移",
  importWritingImage: "导入写作图片", gitIndexUpdate: "更新 Git 索引", gitOperation: "执行 Git 操作",
  metadataBatch: "批量标签与分类", remoteReview: "远程评审", knowledgeImport: "导入资料", knowledgeExport: "导出资料", knowledgeArchiveExport: "导出资料归档",
};
export const OPERATION_CATEGORY_LABELS: Record<OperationCategory, string> = { writing: "写作", draft: "草稿", image: "图片", publish: "发布", knowledge: "资料" };
const CATEGORY_BY_KIND: Record<OperationKind, OperationCategory> = {
  saveDocument: "writing", createDocument: "writing", renameDocument: "writing", deleteDocument: "writing",
  restoreDraftVersion: "draft", restoreRecycledDraft: "draft", deleteRecycledDraft: "draft", saveGeneralDraft: "draft", transferGeneralDraft: "draft", undoGeneralDraftTransfer: "draft",
  importWritingImage: "image", gitIndexUpdate: "publish", gitOperation: "publish", remoteReview: "publish",
  metadataBatch: "writing", knowledgeImport: "knowledge", knowledgeExport: "knowledge", knowledgeArchiveExport: "knowledge",
};

export function operationKindLabel(kind: OperationKind): string { return OPERATION_KIND_LABELS[kind] ?? "未知操作"; }
export function operationCategory(kind: OperationKind): OperationCategory { return CATEGORY_BY_KIND[kind] ?? "writing"; }
export const categoryForOperation = operationCategory;

export function formatOperationDate(epochMs: number): string {
  const date = new Date(epochMs);
  return Number.isFinite(date.getTime()) ? date.toLocaleString() : "时间未知";
}
export function formatOperationDuration(durationMs: number): string {
  if (!Number.isFinite(durationMs) || durationMs < 0) return "耗时未知";
  if (durationMs < 1_000) return `${Math.round(durationMs)} 毫秒`;
  if (durationMs < 60_000) return `${(durationMs / 1_000).toFixed(1)} 秒`;
  return `${Math.floor(durationMs / 60_000)} 分 ${(durationMs % 60_000 / 1_000).toFixed(1)} 秒`;
}

export interface OperationLogFilters { category: OperationCategory | "all"; outcome: OperationOutcomeFilter; repository: OperationRepositoryFilter; query: string; }
export function filterOperationLog(entries: readonly OperationLogEntry[], filters: OperationLogFilters, currentRepositoryKey: string | null): OperationLogEntry[] {
  const needle = filters.query.trim().toLocaleLowerCase();
  return entries.filter((entry) => {
    if (filters.category !== "all" && operationCategory(entry.kind) !== filters.category) return false;
    if (filters.outcome !== "all" && entry.outcome !== filters.outcome) return false;
    if (filters.repository === "current" && (!currentRepositoryKey || entry.repositoryKey !== currentRepositoryKey)) return false;
    if (filters.repository === "unlinked" && entry.repositoryKey !== null) return false;
    return !needle || operationKindLabel(entry.kind).toLocaleLowerCase().includes(needle);
  }).sort((a, b) => b.occurredAtEpochMs - a.occurredAtEpochMs || b.sequence - a.sequence);
}
export const filterOperationEntries = filterOperationLog;

export function repositoryDisplayName(key: string | null, currentKey: string | null): string {
  if (!key) return "未关联仓库";
  if (key === currentKey) return "当前仓库";
  const compact = key.replace(/[^a-zA-Z0-9]/g, "");
  return `其他仓库 · ${compact.slice(0, 8) || "未知"}`;
}
