# RayMol — Sandbox & subprocess audit

## fetch_path (file writes)
Already sandbox-safe: `PyMOLEngine` init sets `cmd.set('fetch_path', <Documents>)`
to the app's Documents directory (container-relative under App Sandbox), so PDB
fetch downloads land in a writable location on macOS and iOS. No change needed.

## Subprocess / external-process audit (bundled `modules/pymol`, `modules/chempy`)
Reviewed all `subprocess`/`os.system`/`Popen`/`exec` call sites. **None are on
RayMol's shipped UI feature paths.** Details:

- `movie.py` (ffmpeg) — RayMol uses its own native AVFoundation movie export
  (MovieExporter), not PyMOL's ffmpeg path.
- `editing.py` (`clean`, external tool version check), `querying.py` (external
  converter), `cgo.py` (`molauto`/`molscript`) — legacy/desktop conversions not
  exposed in the RayMol UI.
- `externing.py` (pbpaste/xclip/powershell clipboard) — RayMol uses native
  clipboard; this path is not wired.
- `xwin.py` (`wish`/Tk) — no Tk in the embedded build.

Under App Sandbox, any of these (only reachable by a power-user typing the exact
command) would be **denied by the sandbox and fail gracefully** — they cannot
crash the app or escape the sandbox. No code removal required for App Store.

## Console sandbox-denial audit (Task 5)
_To be completed against the signed, sandboxed Release build once the Apple
account is added to Xcode. Procedure: run the signed build with
`log stream --predicate 'process == "RayMol" AND eventMessage CONTAINS "deny"'`,
exercise every feature (open/fetch/save/PNG+session export/all reps/themes/
measurements/timeline+movie/command line), and confirm zero `deny` lines; fix any
by adding the matching entitlement or rerouting the path._
