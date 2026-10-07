---
name: research-documents
description: Create or edit research reports, tables and slides in DOCX, XLSX, PPTX or PDF, with explicit data sources and format validation. Use for document artifacts rather than scientific inference.
---

# Research documents

This is an independently authored workflow for Chem Science Workbench.
The bundled exporter creates simple reports and tables; for complex layouts or
edits to an existing file, use the same format libraries directly and preserve
the original. The exporter does not round-trip an existing Office document.

Use the project's selected Python environment. If dependencies are missing,
install `requirements.txt` into that environment within the user's authorization.
Do not install packages into a system interpreter implicitly.

For a new document, prepare a UTF-8 JSON file with:

- `title`: document title.
- `sections`: objects containing `heading` and a list of `paragraphs`.
- `table` (optional): `columns` and `rows`; values are text, numbers or null.
- `sources` (optional): source identifiers or paths supplied or verified during
  the task. Never invent citations to fill this field.

Run `python scripts/export_document.py input.json output.docx` (or `.xlsx`,
`.pptx`, `.pdf`), relative to this skill directory. Existing outputs are refused
unless `--overwrite` is explicitly supplied. The script paths and input paths
must be quoted when they contain spaces. Files and directories created by the
command are real artifacts; include them in the task's run/provenance record.

The spreadsheet exporter keeps strings literal, including leading `=`. It does
not evaluate spreadsheet formulas or preserve macros. Label missing values and
units in the input; no inference or silent unit conversion is performed.

After export, reopen the file with its format reader and check the title,
critical numbers, table dimensions and sources. Inspect the actual rendering
when layout matters. PDF uses a CJK-capable CID font; it is not an embedded-font
archival PDF. PPTX uses short paragraphs and paginated tables; split lengthy
content before export and check the resulting slides. Text extraction alone
does not prove that a layout is visually correct.
