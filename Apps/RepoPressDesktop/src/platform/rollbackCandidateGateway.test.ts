import { describe, expect, it, vi } from "vitest";
import type { RollbackCandidatePlan, RollbackCandidateReport } from "../contracts/rollbackCandidate";
import { createRepositoryGateway } from "./repositoryGateway";

const checkedAtEpochMs = Date.now();
const plan: RollbackCandidatePlan = {
  sessionId: "session-1",
  recordId: "push-1",
  revision: 3,
  branch: "main",
  remoteUrl: "https://example.test/repo.git",
  expectedSha: "a".repeat(40),
  parentSha: "b".repeat(40),
  status: "ready",
  planId: "11111111-1111-4111-8111-111111111111",
  sourceTreeSha: "c".repeat(40),
  targetTreeSha: "d".repeat(40),
  changedPaths: 1,
  targetFiles: 1,
  blockers: [],
  checkedAtEpochMs,
  expiresAtEpochMs: checkedAtEpochMs + 300_000,
};

const report: RollbackCandidateReport = {
  sessionId: plan.sessionId,
  recordId: plan.recordId,
  revision: plan.revision,
  branch: plan.branch,
  remoteUrl: plan.remoteUrl,
  expectedSha: plan.expectedSha,
  parentSha: plan.parentSha,
  planId: plan.planId!,
  sourceTreeSha: plan.sourceTreeSha!,
  targetTreeSha: plan.targetTreeSha!,
  candidateSha: "e".repeat(40),
  changedPaths: plan.changedPaths,
  targetFiles: plan.targetFiles,
  generatedAtEpochMs: checkedAtEpochMs + 10_000,
  temporaryObjectsRemoved: true,
};

describe("rollback candidate gateway", () => {
  it("maps the exact bounded IPC arguments for plan, generate, and discard", async () => {
    const invoke = vi.fn(async <T>(command: string): Promise<T> => {
      if (command === "plan_rollback_candidate") return plan as T;
      if (command === "generate_rollback_candidate") return report as T;
      return undefined as T;
    });
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>);

    await expect(gateway.planRollbackCandidate("session-1", "push-1", 3)).resolves.toEqual(plan);
    await expect(gateway.generateRollbackCandidate("session-1", "11111111-1111-4111-8111-111111111111")).resolves.toEqual(report);
    await expect(gateway.discardRollbackCandidate("session-1", "11111111-1111-4111-8111-111111111111")).resolves.toBeUndefined();
    expect(invoke).toHaveBeenNthCalledWith(1, "plan_rollback_candidate", { sessionId: "session-1", recordId: "push-1", revision: 3 });
    expect(invoke).toHaveBeenNthCalledWith(2, "generate_rollback_candidate", { sessionId: "session-1", planId: "11111111-1111-4111-8111-111111111111" });
    expect(invoke).toHaveBeenNthCalledWith(3, "discard_rollback_candidate", { sessionId: "session-1", planId: "11111111-1111-4111-8111-111111111111" });
    expect(invoke).toHaveBeenCalledTimes(3);
  });

  it("rejects all candidate operations in the browser demo without fabricating a report", async () => {
    const invoke = vi.fn();
    const gateway = createRepositoryGateway();

    await expect(gateway.planRollbackCandidate("demo-session", "push-1", 3)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.generateRollbackCandidate("demo-session", "11111111-1111-4111-8111-111111111111")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardRollbackCandidate("demo-session", "11111111-1111-4111-8111-111111111111")).rejects.toMatchObject({ code: "read_only_demo" });
    expect(invoke).not.toHaveBeenCalled();
  });
});
