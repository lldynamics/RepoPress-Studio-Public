import type { GitPushRetryPlan } from "../../contracts/gitPushRetry";

export function isGitPushRetryPlanExpired(plan: Pick<GitPushRetryPlan, "expiresAt">, now = Date.now()): boolean {
  const expiresAt = Date.parse(plan.expiresAt);
  return !Number.isFinite(expiresAt) || expiresAt <= now;
}

export function pushRetryExpiryLabel(plan: Pick<GitPushRetryPlan, "expiresAt">): string {
  return isGitPushRetryPlanExpired(plan) ? "此重试计划已失效，请重新检查远端。" : `计划有效至 ${plan.expiresAt}`;
}

export function boundedPathLabel(paths: readonly string[], maximum = 12): string {
  if (paths.length <= maximum) return paths.join("、") || "无文件路径";
  return `${paths.slice(0, maximum).join("、")}，以及另外 ${paths.length - maximum} 个路径`;
}
