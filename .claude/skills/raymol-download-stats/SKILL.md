---
name: raymol-download-stats
description: Use when checking RayMol GitHub release download counts, DMG install stats, or auto-updater vs manual download breakdown across releases.
---

# RayMol Download Stats

Fetches DMG download counts from GitHub releases and renders a markdown table broken down by auto-updater (versioned DMG, pulled by Sparkle) vs manual installs (`RayMol.dmg`).

## Usage

Run the script from anywhere in the repo:

```bash
python3 .claude/skills/raymol-download-stats/get_stats.py
```

Requires `gh` CLI authenticated to the `javierbq/RayMol` repo.

## Output format

| Release | Published | Auto-updater | Manual | Total |
|---------|-----------|-------------|--------|-------|
| v1.x.x  | Mon DD    | N           | N      | N     |
| **Total** | | **N** | **N** | **N** |

- **Auto-updater**: versioned asset (e.g. `RayMol-1.4.1.dmg`) fetched by Sparkle on existing installs
- **Manual**: `RayMol.dmg` — the always-latest asset downloaded by new users from the releases page
- `—` in Manual means that release had no `RayMol.dmg` asset (e.g. v1.1.0)
