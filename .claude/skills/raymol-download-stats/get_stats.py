#!/usr/bin/env python3
"""Fetch RayMol GitHub release DMG download stats and print a markdown table."""
import json, subprocess, sys

result = subprocess.run(
    ["gh", "api", "/repos/javierbq/RayMol/releases"],
    capture_output=True, text=True
)
if result.returncode != 0:
    print(result.stderr, file=sys.stderr)
    sys.exit(1)

releases = json.loads(result.stdout)

rows = []
for r in releases:
    dmgs = [a for a in r.get("assets", []) if a["name"].endswith(".dmg")]
    if not dmgs:
        continue
    tag = r["tag_name"]
    published = r["published_at"][:10]
    versioned = next((a["download_count"] for a in dmgs if a["name"] != "RayMol.dmg"), 0)
    manual = next((a["download_count"] for a in dmgs if a["name"] == "RayMol.dmg"), None)
    total = versioned + (manual if manual is not None else 0)
    rows.append((tag, published, versioned, manual, total))

print("| Release | Published | Auto-updater | Manual | Total |")
print("|---------|-----------|-------------|--------|-------|")
auto_sum = manual_sum = total_sum = 0
for tag, published, versioned, manual, total in rows:
    manual_str = "—" if manual is None else str(manual)
    print(f"| {tag} | {published[5:]} | {versioned} | {manual_str} | {total} |")
    auto_sum += versioned
    manual_sum += manual if manual is not None else 0
    total_sum += total

print(f"| **Total** | | **{auto_sum}** | **{manual_sum}** | **{total_sum}** |")
