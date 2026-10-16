import type { AppUpdateCheck, AppUpdatePlan } from "../../contracts/repository";

export function isAppUpdatePlanExpired(plan: AppUpdatePlan, now = Date.now()): boolean {
  const expires = Date.parse(plan.expiresAt);
  return !Number.isFinite(expires) || expires <= now;
}

export function canCheckAppUpdate(readiness: { configured: boolean; ready: boolean } | null, isDemo: boolean): boolean {
  return !isDemo && Boolean(readiness?.configured && readiness.ready);
}

export function visibleAppUpdatePlan(check: AppUpdateCheck): AppUpdatePlan | null {
  return check.supported && check.configured && check.available ? check.plan : null;
}
