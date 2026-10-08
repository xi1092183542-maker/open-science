// Actual replacement parser checks for the old renderer's regressions.
import { describe, expect, it } from "vitest";
import JSZip from "jszip";
import { buildPresentation, parseZip, RECOMMENDED_ZIP_LIMITS } from "@aiden0z/pptx-renderer";
import { restrictPptxRelationships } from "./pptx-relationships";

const P = "http://schemas.openxmlformats.org/presentationml/2006/main";
const A = "http://schemas.openxmlformats.org/drawingml/2006/main";
const R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
const REL = "http://schemas.openxmlformats.org/package/2006/relationships";
async function deck() {
  const zip = new JSZip();
  zip.file("[Content_Types].xml", '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/ppt/slideMasters/missing.xml" ContentType="application/xml"/></Types>');
  zip.file("ppt/presentation.xml", `<p:presentation xmlns:p="${P}" xmlns:r="${R}"><p:sldIdLst><p:sldId id="257" r:id="second"/><p:sldId id="256" r:id="first"/></p:sldIdLst><p:sldSz cx="9144000" cy="5143500"/></p:presentation>`);
  zip.file("ppt/_rels/presentation.xml.rels", `<Relationships xmlns="${REL}"><Relationship Id="first" Type="${R}/slide" Target="slides/slide1.xml"/><Relationship Id="second" Type="${R}/slide" Target="slides/slide2.xml"/></Relationships>`);
  for (const [n, text] of [[1, "First"], [2, "配方研发 <script>alert(1)</script>"]] as const) {
    zip.file(`ppt/slides/slide${n}.xml`, `<p:sld xmlns:p="${P}" xmlns:a="${A}" xmlns:r="${R}"><p:cSld><p:spTree><p:sp><p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="9144000" cy="914400"/></a:xfrm></p:spPr><p:txBody><a:bodyPr/><a:p><a:pPr><a:defRPr sz="4800" b="1"><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill></a:defRPr></a:pPr><a:r><a:t>${text.replace(/</g, "&lt;").replace(/>/g, "&gt;")}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>`);
  }
  zip.file("ppt/slides/_rels/slide2.xml.rels", `<Relationships xmlns="${REL}"><Relationship Id="external" Type="${R}/image" Target="https://example.invalid/tracker.png" TargetMode="External"/></Relationships>`);
  return zip.generateAsync({ type: "uint8array" });
}

describe("replacement PPTX parser", () => {
  it("preserves slide order, Unicode and paragraph defaults despite phantom parts", async () => {
    const bytes = await deck();
    const before = new Uint8Array(bytes);
    const files = await parseZip(bytes as unknown as ArrayBuffer, RECOMMENDED_ZIP_LIMITS);
    expect(restrictPptxRelationships(files)).toBe(1);
    expect(files.slideRels.get("ppt/slides/_rels/slide2.xml.rels") ?? [...files.slideRels.values()].join("")).not.toContain("example.invalid");
    const model = buildPresentation(files);
    expect(model.slides).toHaveLength(2);
    expect(model.width).toBe(960);
    const title = model.slides[0].nodes[0];
    expect(title.nodeType).toBe("shape");
    if (title.nodeType !== "shape") throw new Error("Missing text shape");
    const paragraph = title.textBody!.paragraphs[0];
    expect(paragraph.runs[0].text).toBe("配方研发 <script>alert(1)</script>");
    expect(paragraph.properties!.child("defRPr").attr("sz")).toBe("4800");
    expect(files.media.size).toBe(0);
    expect(bytes).toEqual(before);
  });
  it("rejects malformed archives", async () => {
    await expect(parseZip(new Uint8Array([1, 2, 3]) as unknown as ArrayBuffer, RECOMMENDED_ZIP_LIMITS)).rejects.toThrow();
  });
  it("enforces archive resource limits before rendering", async () => {
    await expect(parseZip(await deck() as unknown as ArrayBuffer, { maxEntries: 1 })).rejects.toThrow();
  });
  it("blocks encoded, file and network resource targets while retaining click-only HTTPS links", async () => {
    const files = await parseZip(await deck() as unknown as ArrayBuffer);
    files.chartRels = new Map([["chart", `<Relationships xmlns="${REL}"><Relationship Id="a" Target="file:///secret.png"/><Relationship Id="b" Target="%68ttps%3A%2F%2Fexample.invalid/x"/><Relationship Id="c" Target="//example.invalid/x"/><Relationship Id="d" Type="${R}/hyperlink" Target="https://example.invalid/paper" TargetMode="External"/></Relationships>`]]);
    expect(restrictPptxRelationships(files)).toBe(4);
    expect(files.chartRels.get("chart")).toContain("/paper");
    expect(files.chartRels.get("chart")).not.toContain("secret");
  });
});
