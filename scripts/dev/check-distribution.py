"""Verify staged notice integrity and distinguish internal builds from public clearance.

This checks recorded evidence, not license interpretation or release authorization.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]


def check(index_path, purpose):
    index_path = Path(index_path).resolve()
    data = json.loads(index_path.read_text(encoding="utf8"))
    required = {"components", "missingNoticeFiles", "prebundledJavaScript",
                "licenseReviewIssues", "remainingReview"}
    if data.get("schema") != 1 or not required.issubset(data):
        raise ValueError("Unsupported or incomplete distribution evidence")
    if any(not isinstance(data[key], list) for key in required) or not data["components"]:
        raise ValueError("Distribution evidence must contain nonempty component inventory and review lists")
    checked = 0
    identifiers = set()
    missing = set()
    for component in data["components"]:
        identifier = f"{component['kind']}:{component['name']}@{component['version']}"
        if identifier in identifiers:
            raise ValueError("Duplicate component: " + identifier)
        identifiers.add(identifier)
        notices = component["notices"]
        if not isinstance(notices, list):
            raise ValueError("Invalid notices: " + identifier)
        if not notices:
            missing.add(identifier)
        records = list(notices)
        if component.get("unmodifiedSourceArchive"):
            records.append(component["unmodifiedSourceArchive"])
        for record in records:
            relative = Path(record["path"])
            target = (index_path.parent / relative).resolve()
            if relative.is_absolute() or not target.is_relative_to(index_path.parent):
                raise ValueError("Notice path escapes staged directory")
            if not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest() != record["sha256"]:
                raise ValueError("Missing or altered notice/source archive: " + record["path"])
            checked += 1
    if missing != set(data["missingNoticeFiles"]):
        raise ValueError("Missing-notice list does not match component records")
    blockers = []
    if data.get("distributionCleared") is not True:
        blockers.append("Distribution review is not cleared")
    if missing:
        blockers.append(f"{len(missing)} components lack verified notice text")
    if data["licenseReviewIssues"]:
        blockers.append(f"{len(data['licenseReviewIssues'])} unresolved license issues")
    if data["prebundledJavaScript"]:
        blockers.append("Embedded JavaScript coverage requires review")
    if data["remainingReview"]:
        blockers.extend(data["remainingReview"])
    return {"purpose": purpose, "integrityVerified": True, "components": len(identifiers),
            "checkedFiles": checked, "publicDistributionCleared": not blockers,
            "blockers": blockers, "pass": purpose == "internal" or not blockers}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=Path, default=ROOT / "runtime/third-party-notices/dependencies/index.json")
    parser.add_argument("--purpose", choices=("internal", "public"), required=True)
    args = parser.parse_args()
    try:
        result = check(args.index, args.purpose)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"purpose": args.purpose, "pass": False, "error": str(error)}))
        return 1
    print(json.dumps(result))
    return 0 if result["pass"] else 2


if __name__ == "__main__":
    sys.exit(main())
