import { describe, expect, it, vi } from "vitest";
import { createRepositoryGateway } from "./repositoryGateway";

describe("AI connection gateway", () => {
  const request = { operation: "models", provider: "ollama_local", endpoint: "http://127.0.0.1:11434/v1", model: "" } as const;
  it("plans discovery without a model or document context, then sends the approved identifier", async () => {
    const call = vi.fn().mockResolvedValue({});
    const gateway = createRepositoryGateway(call);
    await gateway.planAiConnection(request);
    await gateway.executeAiConnection({ ...request, planId: "approved-plan" });
    expect(call.mock.calls).toEqual([
      ["plan_ai_connection", request],
      ["execute_ai_connection", { ...request, planId: "approved-plan" }],
    ]);
  });
  it("keeps browser demo offline", async () => {
    const gateway = createRepositoryGateway();
    await expect(gateway.planAiConnection(request)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeAiConnection({ ...request, planId: "p" })).rejects.toMatchObject({ code: "read_only_demo" });
  });
  it("allows endpoint-scoped credential preparation before choosing a model", async () => {
    const call = vi.fn().mockResolvedValue({}); const gateway = createRepositoryGateway(call);
    const config = { provider: "openai_compatible", endpoint: "https://example.invalid/v1", model: "" } as const;
    await gateway.aiCredentialStatus(config);
    await gateway.storeAiCredential({ ...config, token: "fixture-token" });
    await gateway.deleteAiCredential(config);
    expect(call.mock.calls).toEqual([
      ["ai_credential_status", config],
      ["store_ai_credential", { ...config, token: "fixture-token" }],
      ["delete_ai_credential", config],
    ]);
  });
});
