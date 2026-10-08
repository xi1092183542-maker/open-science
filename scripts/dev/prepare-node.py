"""Install the pinned Windows Node toolchain locally, checking official SHA-256."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    version = (ROOT / ".node-version").read_text().strip()
    name = f"node-v{version}-win-x64.zip"
    url = f"https://nodejs.org/dist/v{version}/"
    destination = args.destination.resolve()
    destination.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url + "SHASUMS256.txt", timeout=60) as response:
        sums = response.read().decode("utf8")
    expected = next(line.split()[0] for line in sums.splitlines() if line.split()[-1] == name)
    lockfile = ROOT / "scripts/dev/node-toolchain-lock.json"
    record = {"version": version, "url": url + name, "sha256": expected,
              "verification": "SHA-256 from official HTTPS SHASUMS256.txt; release signature not verified"}
    if lockfile.exists() and json.loads(lockfile.read_text()) != record:
        raise ValueError("Node release differs from the reviewed toolchain lock")
    archive = destination / name
    if not archive.exists():
        partial = archive.with_suffix(".partial")
        print(f"Downloading Node {version}", flush=True)
        with urllib.request.urlopen(url + name, timeout=60) as response, partial.open("wb") as target:
            while block := response.read(1024 * 1024):
                target.write(block)
        partial.replace(archive)
    if digest(archive) != expected:
        raise ValueError("Node archive checksum mismatch")
    with zipfile.ZipFile(archive) as source:
        for member in source.infolist():
            target = (destination / member.filename).resolve()
            if not target.is_relative_to(destination):
                raise ValueError("Unsafe archive member")
        source.extractall(destination)
    lockfile.write_text(json.dumps(record, indent=2) + "\n", encoding="utf8")
    print(destination / f"node-v{version}-win-x64/node.exe")


if __name__ == "__main__":
    main()
