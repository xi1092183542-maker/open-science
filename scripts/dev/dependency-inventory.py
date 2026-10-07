"""Record installed dependency license metadata; not a distribution clearance."""
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("cargo_metadata", type=Path)
parser.add_argument("output", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
raw = args.cargo_metadata.read_bytes()
meta = json.loads(raw.decode("utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"))
node = {}
for pattern in ("*/node_modules/*/package.json", "*/node_modules/@*/*/package.json"):
    for file in (root / "node_modules/.pnpm").glob(pattern):
        package = json.loads(file.read_text(encoding="utf8"))
        if package.get("name") and package.get("version"):
            node[(package["name"], package["version"])] = {
                "name": package["name"], "version": package["version"],
                "license": package.get("license", "UNDECLARED"),
                "scope": "installed build dependency; not necessarily shipped",
            }
result = {
    "status": "Declared metadata only; check actual shipped code and notices before distribution.",
    "node": sorted(node.values(), key=lambda p: p["name"]),
    "rust_windows": [{"name": p["name"], "version": p["version"], "license": p.get("license"),
                      "license_file": bool(p.get("license_file"))} for p in meta["packages"]],
}
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf8")
print(f"Recorded {len(node)} Node and {len(meta['packages'])} Rust package declarations.")
