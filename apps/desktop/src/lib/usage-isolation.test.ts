import { expect, it, vi } from "vitest";
const { invoke } = vi.hoisted(() => ({ invoke: vi.fn() }));
vi.mock("./tauri", () => ({ isTauri: true }));
vi.mock("@tauri-apps/api/core", () => ({ invoke }));
import { fetchUsage } from "./usage";

it("refreshes workbench usage without querying external CLI subscription credentials", async () => {
  const summary = { agents: [], sessions: [], codexRateLimits: [], scannedFiles: 0, skippedFiles: 0, scanMs: 0 };
  invoke.mockResolvedValue(summary);
  expect(await fetchUsage(new Date("2026-10-07T12:00:00Z"))).toEqual(summary);
  expect(invoke).toHaveBeenCalledTimes(1);
  expect(invoke).toHaveBeenCalledWith("agent_usage", expect.objectContaining({ todayStartMs: expect.any(Number), weekStartMs: expect.any(Number) }));
});
