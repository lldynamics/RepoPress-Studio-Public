import { describe, expect, it, vi } from "vitest";
import { createRepositoryGateway } from "./repositoryGateway";

describe("release ledger gateway", () => {
  it("passes only the session identifier to the IPC command", async () => {
    const invoke = vi.fn(async <T>(_command: string, _args?: object): Promise<T> => ({
      sessionId: "session-1",
      entries: [],
      partialSources: [],
      warnings: [],
      summary: { total: 0, verifiedPushes: 0, verifiedReviews: 0, needsAttention: 0 },
    } as T));
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>);

    await gateway.getReleaseLedger("session-1");

    expect(invoke).toHaveBeenCalledWith("get_release_ledger", { sessionId: "session-1" });
    expect(invoke).toHaveBeenCalledTimes(1);
  });

  it("returns a partial unavailable projection in browser demo mode without IPC", async () => {
    const invoke = vi.fn();
    const gateway = createRepositoryGateway();

    const snapshot = await gateway.getReleaseLedger("demo-session");

    expect(snapshot).toMatchObject({
      sessionId: "demo-session",
      entries: [],
      partialSources: ["gitPush", "remoteReview", "rollback"],
      rollbackDiagnostics: {
        status: "unavailable",
        capacity: "unavailable",
        globalRecords: null,
        payloadBytes: null,
        remainingPayloadBytes: null,
        localRecords: null,
        localUnresolved: null,
        maxRecords: 200,
        maxPayloadBytes: 4194304,
        maxRecordBytes: 65536,
        reservedObservationBytes: 51200,
        scopePartial: true,
        blockedTargets: [],
        checkedAtEpochMs: expect.any(Number),
      },
    });
    expect(snapshot.warnings.join(" ")).toContain("浏览器演示");
    expect(invoke).not.toHaveBeenCalled();
  });
});
