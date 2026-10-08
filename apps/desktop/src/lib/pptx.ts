// Local PPTX preview. The caller owns one viewer per document effect.
import { PptxViewer, RECOMMENDED_ZIP_LIMITS, parseZipLazyMedia, buildPresentation } from "@aiden0z/pptx-renderer";
import { restrictPptxRelationships } from "./pptx-relationships";

export function createPptxPreview(
  container: HTMLElement,
  bytes: ArrayBuffer,
  scrollContainer: HTMLElement | undefined,
  onPartialRender: () => void,
) {
  const controller = new AbortController();
  const viewer = new PptxViewer(container, {
    fitMode: "contain",
    scrollContainer,
    zipLimits: RECOMMENDED_ZIP_LIMITS,
    pdfjs: false,
    onSlideError: onPartialRender,
    onNodeError: onPartialRender,
  });
  let destroyed = false;
  const destroy = () => {
    if (destroyed) return;
    destroyed = true;
    controller.abort();
    viewer.destroy();
  };
  const checkCancelled = () => {
    if (controller.signal.aborted) throw new DOMException("Preview aborted", "AbortError");
  };
  const ready = (async () => {
    const files = await parseZipLazyMedia(bytes, RECOMMENDED_ZIP_LIMITS);
    checkCancelled();
    if (restrictPptxRelationships(files)) onPartialRender();
    const model = buildPresentation(files, { lazySlides: true });
    checkCancelled();
    if (!model.slides.length) throw new Error("No slides found in this presentation.");
    viewer.load(model);
    await viewer.renderList({ windowed: true, initialSlides: 4, batchSize: 4 });
    checkCancelled();
  })().then(() => {
    checkCancelled();
  }).catch((error: unknown) => {
    destroy();
    throw error;
  });
  return { ready, destroy };
}
