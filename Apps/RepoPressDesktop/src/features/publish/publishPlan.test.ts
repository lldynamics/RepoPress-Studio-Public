import { describe, expect, it } from "vitest";
import { isPlanExpired, planExpiryLabel, storageLabel } from "./publishPlan";

describe("publish plan helpers", () => {
  it("blocks expired and malformed plans before confirmation", () => {
    const now = new Date("2026-09-03T00:00:00Z");
    expect(isPlanExpired({ expiresAt: "2026-09-02T23:59:59Z" }, now)).toBe(true);
    expect(isPlanExpired({ expiresAt: "not-a-date" }, now)).toBe(true);
    expect(isPlanExpired({ expiresAt: "2026-09-03T00:00:01Z" }, now)).toBe(false);
  });
  it("labels secret storage without exposing a token", () => {
    expect(storageLabel("secret_service")).toBe("Secret Service");
    expect(storageLabel("session_only")).toBe("仅本次会话");
    expect(planExpiryLabel("not-a-date")).toContain("过期");
  });
});
