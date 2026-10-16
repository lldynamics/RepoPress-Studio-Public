import type { GitOperationPlan, RemoteReviewPlan } from "../../contracts/repository";

export function isPlanExpired(plan: Pick<GitOperationPlan | RemoteReviewPlan, "expiresAt">, now = new Date()): boolean {
  const expiresAt = Date.parse(plan.expiresAt);
  return !Number.isFinite(expiresAt) || expiresAt <= now.getTime();
}

export function planExpiryLabel(expiresAt: string, now = new Date()): string {
  const timestamp = Date.parse(expiresAt);
  if (!Number.isFinite(timestamp) || timestamp <= now.getTime()) return "计划已过期，请重新生成。";
  return `计划将在 ${new Date(timestamp).toLocaleString()} 过期。`;
}

export function storageLabel(storage: "secret_service" | "session_only" | "unavailable"): string {
  return { secret_service: "Secret Service", session_only: "仅本次会话", unavailable: "不可用" }[storage];
}
