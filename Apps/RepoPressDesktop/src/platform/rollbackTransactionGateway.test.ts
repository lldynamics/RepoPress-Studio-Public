import { describe, expect, it, vi } from "vitest";
import type { RollbackRecord, RollbackTransactionPlan } from "../contracts/rollbackTransaction";
import { createRepositoryGateway } from "./repositoryGateway";

const sha = (letter: string) => letter.repeat(40);
const plan: RollbackTransactionPlan = {
  sessionId: "session-1",
  recordId: "push-1",
  revision: 4,
  branch: "main",
  remoteUrl: "https://example.test/repo.git",
  expectedSha: sha("a"),
  parentSha: sha("b"),
  status: "ready",
  planId: "123e4567-e89b-12d3-a456-426614174000",
  sourceTreeSha: sha("c"),
  targetTreeSha: sha("d"),
  changedPaths: 2,
  targetFiles: 1,
  blockers: [],
  checkedAtEpochMs: 1_700_000_000_000,
  expiresAtEpochMs: 1_700_000_060_000,
  candidateSha: sha("e"),
  observedRemoteSha: sha("a"),
};

const record: RollbackRecord = {
  planId: "123e4567-e89b-12d3-a456-426614174000",
  sessionId: "session-1",
  recordId: "push-1",
  revision: 4,
  source: {
    recordId: "push-1",
    revision: 4,
    evidence: {
      repositoryPath: "/repo",
      repositoryIdentity: "repo-id",
      operation: "push",
      remote: "origin",
      remoteUrl: "https://example.test/repo.git",
      branch: "main",
      expectedSha: sha("a"),
      observedBeforeSha: sha("b"),
      changedPaths: ["docs/a.md"],
    },
    outcome: "verified",
    observedRemoteSha: sha("a"),
    startedAtEpochMs: 1_699_999_000_000,
    checkedAtEpochMs: 1_699_999_100_000,
  },
  parentSha: sha("b"),
  sourceTreeSha: sha("c"),
  targetTreeSha: sha("d"),
  candidateSha: sha("e"),
  changedPaths: 2,
  targetFiles: 1,
  outcome: "candidateObserved",
  observedRemoteSha: sha("e"),
  candidateObservedAtEpochMs: 1_700_000_005_000,
  startedAtEpochMs: 1_700_000_000_000,
  checkedAtEpochMs: 1_700_000_010_000,
};

describe("rollback transaction gateway", () => {
  it("maps the exact bounded IPC arguments for plan, execute, discard, history, and verify", async () => {
    const invoke = vi.fn(async <T>(command: string): Promise<T> => {
      if (command === "plan_rollback_transaction") return plan as T;
      if (command === "execute_rollback_transaction") return record as T;
      if (command === "list_rollback_records") return [record] as T;
      if (command === "verify_rollback_record") return record as T;
      return undefined as T;
    });
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>);

    await expect(gateway.planRollbackTransaction("session-1", "push-1", 4)).resolves.toEqual(plan);
    await expect(gateway.executeRollbackTransaction("session-1", plan.planId!)).resolves.toEqual(record);
    await expect(gateway.discardRollbackTransaction("session-1", plan.planId!)).resolves.toBeUndefined();
    await expect(gateway.listRollbackRecords("session-1")).resolves.toEqual([record]);
    await expect(gateway.verifyRollbackRecord("session-1", "push-1", 4)).resolves.toEqual(record);

    expect(invoke).toHaveBeenNthCalledWith(1, "plan_rollback_transaction", { sessionId: "session-1", recordId: "push-1", revision: 4 });
    expect(invoke).toHaveBeenNthCalledWith(2, "execute_rollback_transaction", { sessionId: "session-1", planId: plan.planId });
    expect(invoke).toHaveBeenNthCalledWith(3, "discard_rollback_transaction", { sessionId: "session-1", planId: plan.planId });
    expect(invoke).toHaveBeenNthCalledWith(4, "list_rollback_records", { sessionId: "session-1" });
    expect(invoke).toHaveBeenNthCalledWith(5, "verify_rollback_record", { sessionId: "session-1", recordId: "push-1", revision: 4 });
    expect(invoke).toHaveBeenCalledTimes(5);
  });

  it("rejects every transaction action in browser demo mode without invoking IPC", async () => {
    const invoke = vi.fn();
    const gateway = createRepositoryGateway();

    await expect(gateway.planRollbackTransaction("demo-session", "push-1", 4)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeRollbackTransaction("demo-session", plan.planId!)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardRollbackTransaction("demo-session", plan.planId!)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.listRollbackRecords("demo-session")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.verifyRollbackRecord("demo-session", "push-1", 4)).rejects.toMatchObject({ code: "read_only_demo" });
    expect(invoke).not.toHaveBeenCalled();
  });
});
