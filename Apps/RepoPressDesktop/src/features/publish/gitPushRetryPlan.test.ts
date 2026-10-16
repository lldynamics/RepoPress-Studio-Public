import { describe, expect, it } from "vitest";
import { boundedPathLabel, isGitPushRetryPlanExpired, pushRetryExpiryLabel } from "./gitPushRetryPlan";

describe("git push retry plan presentation", () => {
  it("fails closed for malformed and elapsed expiry values", () => {
    expect(isGitPushRetryPlanExpired({ expiresAt: "not-a-date" })).toBe(true);
    expect(isGitPushRetryPlanExpired({ expiresAt: "2026-09-12T00:00:00Z" }, Date.parse("2026-09-12T00:00:01Z"))).toBe(true);
    expect(pushRetryExpiryLabel({ expiresAt: "not-a-date" })).toContain("失效");
  });

  it("keeps a bounded path preview while retaining the actual count", () => {
    expect(boundedPathLabel(["a.md", "b.md"], 2)).toBe("a.md、b.md");
    expect(boundedPathLabel(["a", "b", "c"], 2)).toBe("a、b，以及另外 1 个路径");
  });
});
