#!/usr/bin/env bash
# Fetch the pinned external skill packs into runtime/skills/external/
# (git-ignored; bundled into the installer as Tauri resources).
# Runs locally and in CI so the skills never live in this repo's git history.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# ---- ai4s-skills: the default scientific pack ----
AI4S_SKILLS_COMMIT="${AI4S_SKILLS_COMMIT:-2519e8d11fd49429fb41d39c2f35b7d453814b11}"
OUT_DIR="$ROOT/runtime/skills/external/ai4s-skills"

URL="https://github.com/ai4s-research/ai4s-skills/archive/${AI4S_SKILLS_COMMIT}.tar.gz"
TMP="$(mktemp -d)"
echo "Downloading $URL"
curl -fsSL "$URL" -o "$TMP/skills.tar.gz"
tar -xzf "$TMP/skills.tar.gz" -C "$TMP"

SRC="$(find "$TMP" -maxdepth 1 -type d -name 'ai4s-skills-*' | head -1)"
[ -d "$SRC/skills" ] || { echo "No skills/ directory in archive" >&2; exit 1; }

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp -R "$SRC/skills/." "$OUT_DIR/"
cp "$SRC/LICENSE" "$OUT_DIR/LICENSE"
echo "$AI4S_SKILLS_COMMIT" > "$OUT_DIR/.commit"
rm -rf "$TMP"

echo "Placed ai4s-skills@${AI4S_SKILLS_COMMIT:0:7} in $OUT_DIR:"
ls "$OUT_DIR"

# Office workflows are independently authored and tracked in runtime/skills/office.
# Do not fetch anthropics/skills: its skill-level licenses are not covered by
# this repository's MIT license. Keep upstream scientific-pack attribution.
