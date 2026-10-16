import type { GitChangedFile, GitIndexAction } from "../../contracts/repository";

export function indexActionEligible(file: GitChangedFile, action: GitIndexAction): boolean {
  if (file.sourcePath !== null) return false;
  const status = file.status.padEnd(2, " ");
  const staged = status[0] !== " " && status[0] !== "?";
  const worktree = status[1] !== " " || status.startsWith("??");
  return action === "stage" ? worktree : staged;
}

export function indexStatusLabel(status: string): string {
  const value = status.padEnd(2, " ");
  if (value.startsWith("??")) return "未跟踪";
  if (value[0] !== " " && value[1] !== " ") return "已暂存 + 工作区";
  if (value[0] !== " ") return "已暂存";
  if (value[1] !== " ") return "工作区修改";
  return status || "未知";
}
