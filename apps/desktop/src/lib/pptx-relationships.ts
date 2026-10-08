import type { PptxFiles } from "@aiden0z/pptx-renderer";

// Linked media must not contact a server merely because a file was previewed.
// Keep ordinary HTTP(S)/mailto hyperlinks: the viewer opens them only on click.
export function restrictPptxRelationships(files: PptxFiles): number {
  let removed = 0;
  const clean = (xml: string) => {
    if (!xml) return xml;
    const doc = new DOMParser().parseFromString(xml, "application/xml");
    if (doc.getElementsByTagName("parsererror").length) throw new Error("Invalid presentation relationships.");
    for (const rel of Array.from(doc.getElementsByTagNameNS("*", "Relationship"))) {
      let target = (rel.getAttribute("Target") ?? "").trim();
      try { target = decodeURIComponent(target); } catch { /* Compare the original malformed target. */ }
      const external = rel.getAttribute("TargetMode")?.toLowerCase() === "external" || /^[a-z][a-z0-9+.-]*:|^[\\/]{2}/i.test(target);
      const safeLink = rel.getAttribute("Type")?.endsWith("/hyperlink") && /^(https?:|mailto:)/i.test(target);
      if (external && !safeLink) { rel.remove(); removed++; }
    }
    return new XMLSerializer().serializeToString(doc);
  };
  files.presentationRels = clean(files.presentationRels);
  for (const map of [files.slideRels, files.slideLayoutRels, files.slideMasterRels, files.chartRels]) {
    if (map) for (const [key, value] of map) map.set(key, clean(value));
  }
  return removed;
}
