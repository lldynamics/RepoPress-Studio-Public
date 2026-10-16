import { describe, expect, it, vi } from "vitest";
import type { RollbackQualificationPlan, RollbackQualificationReport } from "../contracts/rollbackQualification";
import { createRepositoryGateway } from "./repositoryGateway";

const plan: RollbackQualificationPlan = {
  sessionId: "session-1",
  recordId: "push-1",
  revision: 3,
  branch: "main",
  remoteUrl: "https://example.test/repo.git",
  expectedSha: "a".repeat(40),
  parentSha: "b".repeat(40),
  localStatus: "candidate",
  blockers: [],
  planId: "rollback-plan-1",
  expiresAtEpochMs: 1_800_000_000_000,
};

const report: RollbackQualificationReport = {
  sessionId: "session-1",
  recordId: "push-1",
  revision: 3,
  branch: "main",
  remoteUrl: "https://example.test/repo.git",
  expectedSha: "a".repeat(40),
  parentSha: "b".repeat(40),
  status: "qualified",
  blockers: [],
  remoteSha: "a".repeat(40),
  checkedAtEpochMs: 1_700_000_000_000,
};

describe("rollback qualification gateway", () => {
  it("passes only the bounded local plan arguments and then the check token", async () => {
    const invoke = vi.fn(async <T>(command: string, _args?: object): Promise<T> => {
      if (command === "plan_rollback_qualification") return plan as T;
      if (command === "check_rollback_qualification") return report as T;
      throw new Error(`unexpected command ${command}`);
    });
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>);

    await expect(gateway.planRollbackQualification("session-1", "push-1", 3)).resolves.toEqual(plan);
    await expect(gateway.checkRollbackQualification("session-1", "rollback-plan-1")).resolves.toEqual(report);

    expect(invoke).toHaveBeenNthCalledWith(1, "plan_rollback_qualification", {
      sessionId: "session-1",
      recordId: "push-1",
      revision: 3,
    });
    expect(invoke).toHaveBeenNthCalledWith(2, "check_rollback_qualification", {
      sessionId: "session-1",
      planId: "rollback-plan-1",
    });
    expect(invoke).toHaveBeenCalledTimes(2);
  });

  it("rejects both qualification actions in browser demo mode without IPC", async () => {
    const invoke = vi.fn();
    const gateway = createRepositoryGateway();

    await expect(gateway.planRollbackQualification("demo-session", "push-1", 1)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.checkRollbackQualification("demo-session", "plan-1")).rejects.toMatchObject({ code: "read_only_demo" });
    expect(invoke).not.toHaveBeenCalled();
  });
});
