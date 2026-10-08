"""Collect license evidence for build inputs and packaged runtime dependencies.

This is a conservative inventory, not a legal opinion or a complete binary SBOM.
Prebundled JavaScript and downloaded sidecar internals remain explicit review items.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tomllib

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "runtime/third-party-notices/dependencies"
NOTICE = re.compile(r"^(licen[sc]e|copying|notice|copyright|authors)([._-]|$)", re.I)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def package_root(file):
    for directory in [file.parent, *file.parents]:
        manifest = directory / "package.json"
        if manifest.is_file():
            data = json.loads(manifest.read_text(encoding="utf8"))
            if data.get("name") and data.get("version"):
                return directory, data
        if directory == ROOT:
            break
    return None


def notice_files(directory):
    # Include nested notices for code vendored inside a package (e.g. ring).
    for file in directory.rglob("*"):
        relative = file.relative_to(directory)
        if "node_modules" in relative.parts or file.is_symlink() or not file.is_file():
            continue
        if NOTICE.match(file.name):
            yield file


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cargo_metadata", type=Path, nargs="?")
    args = parser.parse_args()
    if args.cargo_metadata:
        raw = args.cargo_metadata.read_bytes()
    else:
        # A fresh build may not have downloaded desktop-only crates yet.
        raw = subprocess.check_output(["cargo", "metadata", "--locked", "--filter-platform",
                                       "x86_64-pc-windows-msvc", "--format-version", "1"], cwd=ROOT)
    rust = json.loads(raw.decode("utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"))
    locks = {(p["name"], p["version"]): p for p in tomllib.loads((ROOT / "Cargo.lock").read_text(encoding="utf8"))["package"]}
    fallback_path = ROOT / "scripts/dev/notice-fallbacks.json"
    fallbacks = json.loads(fallback_path.read_text(encoding="utf8")) if fallback_path.exists() else []
    components = {}
    prebundled = []

    def add(kind, directory, meta, scope):
        key = (kind, meta["name"], meta["version"])
        if key not in components:
            components[key] = {"kind": kind, "name": meta["name"], "version": meta["version"],
                               "declaredLicense": meta.get("license"), "scopes": [],
                               "notices": [], "sourceRepository": meta.get("repository"),
                               "_directory": directory, "_meta": meta}
        if scope not in components[key]["scopes"]:
            components[key]["scopes"].append(scope)

    for scope, file in [("frontend", ROOT / "apps/desktop/dist/distribution-inputs.json"),
                        ("acp-server", ROOT / "runtime/acp-server/distribution-inputs.json"),
                        ("goal-plugin-bundle", ROOT / "runtime/goal-plugin/distribution-inputs.json")]:
        for module in json.loads(file.read_text(encoding="utf8"))["modules"]:
            if "node_modules/" not in module:
                continue
            resolved = (ROOT / module).resolve()
            if not resolved.is_relative_to(ROOT):
                raise ValueError("Build input escapes the checkout")
            found = package_root(resolved)
            if found:
                directory, meta = found
                add("npm", directory, meta, scope)
                # Source maps can expose embedded dependencies Rollup cannot see.
                map_file = resolved.with_suffix(resolved.suffix + ".map")
                if map_file.is_file():
                    try:
                        source_map = json.loads(map_file.read_text(encoding="utf8"))
                        sources = source_map.get("sources", [])
                    except (ValueError, UnicodeError):
                        sources = []
                    embedded = sorted({s.split("node_modules/", 1)[1].split("/")[0]
                                       for s in sources if "node_modules/" in s})
                    if embedded:
                        prebundled.append({"module": module, "package": meta["name"],
                                           "embeddedPackageNames": embedded,
                                           "status": "Versions and notices require source-map/upstream-build review"})

    for file in (ROOT / "runtime/goal-plugin/node_modules").rglob("package.json"):
        meta = json.loads(file.read_text(encoding="utf8"))
        if meta.get("name") and meta.get("version"):
            add("npm", file.parent, meta, "packaged-goal-sdk-tree")
    for meta in rust["packages"]:
        if meta.get("source"):
            add("cargo", Path(meta["manifest_path"]).parent, meta,
                "windows-resolved-dependency-superset-including-build-tools")

    OUTPUT.mkdir(parents=True, exist_ok=True)
    missing = []
    for key, record in sorted(components.items()):
        directory, meta = record.pop("_directory"), record.pop("_meta")
        folder = OUTPUT / record["kind"] / f"{record['name'].replace('/', '_')}@{record['version']}"
        folder.mkdir(parents=True, exist_ok=True)
        notices = list(notice_files(directory))
        # Some crates use a license_file outside the conventional naming pattern.
        if record["kind"] == "cargo" and meta.get("license_file"):
            explicit = directory / meta["license_file"]
            if explicit.is_file() and explicit not in notices:
                notices.append(explicit)
        for file in notices:
            relative = file.relative_to(directory)
            target = folder / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(file, target)
            record["notices"].append({"path": target.relative_to(OUTPUT).as_posix(), "sha256": sha(target)})
        if not notices and record["name"] in ("@opencode-ai/plugin", "@opencode-ai/sdk") and record["version"] == "1.18.32":
            source = ROOT / "runtime/third-party-notices/opencode-LICENSE.txt"
            target = folder / "LICENSE.upstream-release.txt"
            shutil.copyfile(source, target)
            record["notices"].append({"path": target.relative_to(OUTPUT).as_posix(), "sha256": sha(target)})
            record["noticeProvenance"] = "MIT notice from the same OpenCode v1.18.32 source release; npm package omits the file"
        if not record["notices"]:
            for fallback in fallbacks:
                if fallback["component"] != f"{record['kind']}:{record['name']}@{record['version']}":
                    continue
                source = (ROOT / "runtime/third-party-notices" / fallback["path"]).resolve()
                if not source.is_relative_to(ROOT / "runtime/third-party-notices") or sha(source) != fallback["sha256"]:
                    raise ValueError("Changed upstream license fallback")
                target = folder / source.name
                shutil.copyfile(source, target)
                record["notices"].append({"path": target.relative_to(OUTPUT).as_posix(), "sha256": sha(target),
                                          "sourceUrl": fallback["url"], "revisionEvidence": fallback["revisionEvidence"]})
        if not record["notices"]:
            missing.append(f"{record['kind']}:{record['name']}@{record['version']}")
        if record["kind"] == "cargo" and "MPL-2.0" in (record["declaredLicense"] or ""):
            archive = directory.parents[2] / "cache" / directory.parent.name / (directory.name + ".crate")
            lock = locks[(record["name"], record["version"])]
            if not archive.is_file() or sha(archive) != lock.get("checksum"):
                raise ValueError(f"Missing or mismatched MPL source archive: {directory.name}")
            target = folder / archive.name
            shutil.copyfile(archive, target)
            record["unmodifiedSourceArchive"] = {"path": target.relative_to(OUTPUT).as_posix(), "sha256": sha(target)}
    result = {"schema": 1, "scope": "Observed JS modules, packaged SDK tree, and conservative Windows Cargo dependency superset",
              "distributionCleared": False, "components": list(components.values()),
              "missingNoticeFiles": missing, "prebundledJavaScript": prebundled,
              "remainingReview": ["Downloaded sidecar executable internals", "Prebundled JavaScript nested license coverage",
                                  "Non-code assets and manual upstream attributions", "Runtime Python dependencies installed by users"]}
    (OUTPUT / "index.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf8")
    print(json.dumps({"components": len(components), "missingNoticeFiles": missing,
                      "prebundledJavaScript": len(prebundled), "distributionCleared": False}))


if __name__ == "__main__":
    main()
