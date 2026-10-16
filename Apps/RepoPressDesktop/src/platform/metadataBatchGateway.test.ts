import { describe, expect, it, vi } from "vitest";
import { createRepositoryGateway } from "./repositoryGateway";

describe("metadata batch gateway", () => {
  it("plans with a session and field operation, then executes only the reviewed plan ID", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    const request = { sessionId: "session", paths: ["a.md", "b.md"], field: "tags" as const, operation: { kind: "rename" as const, value: "old", replacement: "new" } };
    await gateway.planMetadataBatch(request);
    await gateway.executeMetadataBatch("session", "reviewed-plan");
    expect(call.mock.calls).toEqual([
      ["plan_metadata_batch", request],
      ["execute_metadata_batch", { sessionId: "session", planId: "reviewed-plan" }],
    ]);
  });
  it("does not pretend to preview or modify real documents in browser demo", async () => {
    const gateway = createRepositoryGateway();
    expect((await gateway.getCapabilities()).metadataBatch).toBe(false);
    await expect(gateway.planMetadataBatch({ sessionId: "s", paths: ["a.md"], field: "categories", operation: { kind: "add", value: "分类", replacement: null } })).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeMetadataBatch("s", "p")).rejects.toMatchObject({ code: "read_only_demo" });
  });
});
