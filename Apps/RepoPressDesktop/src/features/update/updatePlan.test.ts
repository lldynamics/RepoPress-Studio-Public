import { describe, expect, it } from "vitest";
import type { AppUpdateCheck, AppUpdatePlan } from "../../contracts/repository";
import { canCheckAppUpdate, isAppUpdatePlanExpired, visibleAppUpdatePlan } from "./updatePlan";

const plan: AppUpdatePlan = { planId: "p1", currentVersion: "1.0.0", version: "1.1.0", publishedAt: null, notes: "修复问题", downloadHost: "updates.example", artifactName: "RepoPress.AppImage", expiresAt: "2030-01-01T00:00:00Z", warnings: [] };
const check = (overrides: Partial<AppUpdateCheck> = {}): AppUpdateCheck => ({ supported: true, configured: true, available: true, summary: "有更新", plan, ...overrides });

describe("update plan rules", () => {
  it("recognizes invalid and expired expiry timestamps", () => {
    expect(isAppUpdatePlanExpired({ ...plan, expiresAt: "not-a-date" })).toBe(true);
    expect(isAppUpdatePlanExpired({ ...plan, expiresAt: "2020-01-01T00:00:00Z" }, Date.parse("2021-01-01T00:00:00Z"))).toBe(true);
    expect(isAppUpdatePlanExpired(plan, Date.parse("2029-01-01T00:00:00Z"))).toBe(false);
  });
  it("requires configured and ready native updater", () => {
    expect(canCheckAppUpdate({ configured: true, ready: true }, false)).toBe(true);
    expect(canCheckAppUpdate({ configured: true, ready: false }, false)).toBe(false);
    expect(canCheckAppUpdate({ configured: false, ready: true }, false)).toBe(false);
    expect(canCheckAppUpdate({ configured: true, ready: true }, true)).toBe(false);
  });
  it("only exposes supported available candidates with plans", () => {
    expect(visibleAppUpdatePlan(check())).toEqual(plan);
    expect(visibleAppUpdatePlan(check({ supported: false }))).toBeNull();
    expect(visibleAppUpdatePlan(check({ configured: false }))).toBeNull();
    expect(visibleAppUpdatePlan(check({ available: false }))).toBeNull();
    expect(visibleAppUpdatePlan(check({ plan: null }))).toBeNull();
  });
});
