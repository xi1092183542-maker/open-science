"""Fetch pinned Windows resources without running third-party install scripts.

Uses the versions in the upstream fetch scripts. Downloads are cached and
recorded with SHA-256; recorded downloads are checked before reuse. These local
digests establish a reproducible baseline, not an independent publisher signature.
"""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import shutil
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / ".build-cache"
BIN = ROOT / "apps/desktop/src-tauri/binaries"
TRIPLE = "x86_64-pc-windows-msvc"


def pin(script, name):
    source = (ROOT / "scripts/dev" / script).read_text(encoding="utf-8")
    match = re.search(re.escape(name) + r'="\$\{' + re.escape(name) + r':-([^}]+)\}"', source)
    if not match:
        raise ValueError("missing version pin: " + name)
    return match[1]


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(item):
    name, url = item
    dest = CACHE / name
    lock = ROOT / "scripts/dev/resource-lock.json"
    previous = json.loads(lock.read_text()) if lock.exists() else {}
    if not dest.exists():
        print("Downloading " + name, flush=True)
        partial = dest.with_suffix(dest.suffix + ".partial")
        request = urllib.request.Request(url, headers={"User-Agent": "ChemScienceBuild/0.1"})
        with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as out:
            shutil.copyfileobj(response, out)
        partial.replace(dest)
    digest = sha(dest)
    if name in previous and previous[name] != {"url": url, "sha256": digest}:
        raise ValueError("resource differs from recorded baseline: " + name)
    return name, {"url": url, "sha256": digest}


def copy_archive_tree(archive, prefix, destination):
    destination = destination.resolve()
    with tarfile.open(archive, "r:gz") as source:
        for member in source.getmembers():
            if not member.name.startswith(prefix) or not member.isfile():
                continue
            relative = member.name[len(prefix):]
            if not relative:
                continue
            target = (destination / relative).resolve()
            if not target.is_relative_to(destination):
                raise ValueError("unsafe archive path")
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.extractfile(member) as inp, target.open("wb") as out:
                shutil.copyfileobj(inp, out)


def copy_member(archive, suffix, destination):
    with tarfile.open(archive, "r:gz") as source:
        candidates = [m for m in source.getmembers() if m.isfile() and m.name.endswith(suffix)]
        if len(candidates) != 1:
            raise ValueError("ambiguous or missing archive member: " + suffix)
        destination.parent.mkdir(parents=True, exist_ok=True)
        with source.extractfile(candidates[0]) as inp, destination.open("wb") as out:
            shutil.copyfileobj(inp, out)


def main():
    CACHE.mkdir(exist_ok=True)
    BIN.mkdir(parents=True, exist_ok=True)
    oc = pin("fetch-opencode.sh", "OPENCODE_VERSION")
    uv = pin("fetch-uv.sh", "UV_VERSION")
    browser = pin("fetch-agent-browser.sh", "AGENT_BROWSER_VERSION")
    skills = pin("fetch-skills.sh", "AI4S_SKILLS_COMMIT")
    urls = [
        ("opencode.zip", f"https://github.com/anomalyco/opencode/releases/download/v{oc}/opencode-windows-x64.zip"),
        ("uv.zip", f"https://github.com/astral-sh/uv/releases/download/{uv}/uv-{TRIPLE}.zip"),
        ("agent-browser.exe", f"https://github.com/vercel-labs/agent-browser/releases/download/v{browser}/agent-browser-win32-x64.exe"),
        ("agent-browser.tar.gz", f"https://codeload.github.com/vercel-labs/agent-browser/tar.gz/refs/tags/v{browser}"),
        ("ai4s-skills.tar.gz", f"https://codeload.github.com/ai4s-research/ai4s-skills/tar.gz/{skills}"),
        ("opencode-LICENSE.txt", f"https://raw.githubusercontent.com/anomalyco/opencode/v{oc}/LICENSE"),
        ("uv-LICENSE-MIT.txt", f"https://raw.githubusercontent.com/astral-sh/uv/{uv}/LICENSE-MIT"),
        ("uv-LICENSE-APACHE.txt", f"https://raw.githubusercontent.com/astral-sh/uv/{uv}/LICENSE-APACHE"),
    ]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        records = dict(executor.map(download, urls))
    for name in ("opencode", "uv"):
        with zipfile.ZipFile(CACHE / f"{name}.zip") as archive:
            members = [m for m in archive.namelist() if Path(m).name == name + ".exe"]
            if len(members) != 1:
                raise ValueError("missing/ambiguous binary: " + name)
            with archive.open(members[0]) as inp, (BIN / f"{name}-{TRIPLE}.exe").open("wb") as out:
                shutil.copyfileobj(inp, out)
    shutil.copyfile(CACHE / "agent-browser.exe", BIN / f"agent-browser-{TRIPLE}.exe")
    notices = ROOT / "runtime/third-party-notices"
    notices.mkdir(exist_ok=True)
    for name, _ in urls:
        if "LICENSE" in name:
            shutil.copyfile(CACHE / name, notices / name)
    shutil.copyfile(ROOT / "LICENSE", notices / "open-science-LICENSE.txt")
    copy_member(CACHE / "agent-browser.tar.gz", f"agent-browser-{browser}/LICENSE", notices / "agent-browser-LICENSE.txt")
    copy_member(CACHE / "ai4s-skills.tar.gz", f"ai4s-skills-{skills}/LICENSE", notices / "ai4s-skills-LICENSE.txt")
    external = ROOT / "runtime/skills/external"
    skill_out = external / "ai4s-skills"
    copy_archive_tree(CACHE / "ai4s-skills.tar.gz", f"ai4s-skills-{skills}/skills/", skill_out)
    copy_member(CACHE / "ai4s-skills.tar.gz", f"ai4s-skills-{skills}/LICENSE", skill_out / "LICENSE")
    (skill_out / ".commit").write_text(skills + "\n")
    browser_out = external / "agent-browser/open-science-browser"
    copy_archive_tree(CACHE / "agent-browser.tar.gz", f"agent-browser-{browser}/skill-data/core/", browser_out)
    copy_member(CACHE / "agent-browser.tar.gz", f"agent-browser-{browser}/LICENSE", browser_out / "LICENSE.txt")
    # Reuse the existing upstream MCP adapter without executing its shell script.
    script = (ROOT / "scripts/dev/fetch-agent-browser.sh").read_text(encoding="utf-8")
    adapter = script.split("<<'ADAPTER_EOF'\n", 1)[1].split("\nADAPTER_EOF", 1)[0]
    path = browser_out / "SKILL.md"
    content = path.read_text(encoding="utf-8")
    parts = content.split("---", 2)
    if len(parts) != 3:
        raise ValueError("browser skill has invalid frontmatter")
    header = re.sub(r"(?m)^name: core$", "name: open-science-browser", parts[1])
    header = re.sub(r"(?m)^description:.*$", "description: Use the configured agent_browser MCP tools for interactive browsing. Prefer built-in web fetch and search for plain pages and APIs.", header)
    path.write_text("---" + header + "---\n" + adapter + parts[2], encoding="utf-8")
    (external / "agent-browser/.version").write_text(browser + "\n")
    (ROOT / "scripts/dev/resource-lock.json").write_text(json.dumps(records, indent=2) + "\n")
    print("Prepared Windows sidecars and permitted external skill packs.", flush=True)


if __name__ == "__main__":
    main()
