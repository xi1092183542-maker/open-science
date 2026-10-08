import { beforeEach, describe, expect, it, vi } from "vitest";
const mock = vi.hoisted(() => ({ parse: vi.fn(), render: vi.fn(), load: vi.fn(), destroy: vi.fn(), options: null as any, slideCount: 1 }));
vi.mock("@aiden0z/pptx-renderer", () => ({
  RECOMMENDED_ZIP_LIMITS: { maxEntries: 4000 },
  parseZipLazyMedia: mock.parse,
  buildPresentation: () => ({ slides: Array(mock.slideCount).fill({}) }),
  PptxViewer: class {
    constructor(_container: HTMLElement, options: unknown) { mock.options = options; }
    load = mock.load;
    renderList = mock.render;
    destroy = mock.destroy;
    get slideCount() { return mock.slideCount; }
  },
}));
import { createPptxPreview } from "./pptx";

beforeEach(() => {
  vi.clearAllMocks(); mock.slideCount = 1;
  mock.parse.mockResolvedValue({ presentationRels: "", slideRels: new Map() });
  mock.render.mockResolvedValue(undefined);
});
const start = (partial = vi.fn()) => createPptxPreview(document.createElement("div"), new ArrayBuffer(0), undefined, partial);

describe("PPTX preview ownership", () => {
  it("aborts pending work and releases resources once on close", async () => {
    let reject!: (e: unknown) => void;
    mock.parse.mockImplementation(() => new Promise((_, no) => { reject = no; }));
    const preview = start();
    const result = expect(preview.ready).rejects.toThrow("cancelled");
    preview.destroy(); preview.destroy();
    reject(new Error("cancelled"));
    await result;
    expect(mock.load).not.toHaveBeenCalled();
    expect(mock.destroy).toHaveBeenCalledTimes(1);
  });
  it("cleans up failed loads", async () => {
    mock.parse.mockRejectedValue(new Error("bad deck"));
    await expect(start().ready).rejects.toThrow("bad deck");
    expect(mock.destroy).toHaveBeenCalledTimes(1);
  });
  it("does not render a late parse result after cancellation", async () => {
    let resolve!: (value: unknown) => void;
    mock.parse.mockImplementation(() => new Promise(yes => { resolve = yes; }));
    const preview = start();
    preview.destroy();
    resolve({ presentationRels: "", slideRels: new Map() });
    await expect(preview.ready).rejects.toThrow("Preview aborted");
    expect(mock.load).not.toHaveBeenCalled();
  });
  it("reports an empty deck instead of a successful blank preview", async () => {
    mock.slideCount = 0;
    await expect(start().ready).rejects.toThrow("No slides");
    expect(mock.destroy).toHaveBeenCalledTimes(1);
  });
  it("reports partial failures and disables automatic PDF fallback", async () => {
    const partial = vi.fn();
    const preview = start(partial);
    await preview.ready;
    mock.options.onNodeError(); mock.options.onSlideError();
    expect(partial).toHaveBeenCalledTimes(2);
    expect(mock.options.pdfjs).toBe(false);
    expect(mock.options.zipLimits.maxEntries).toBe(4000);
    preview.destroy();
  });
});
