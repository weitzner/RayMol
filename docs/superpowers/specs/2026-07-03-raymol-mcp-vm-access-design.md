# RayMol MCP: host → VM access for mac-vm-test-driven macOS development

**Date:** 2026-07-03
**Status:** approved, implementing
**Goal:** Make the mac-vm-test skill the primary loop for macOS RayMol development,
which requires the host Claude Code session to drive RayMol *while it runs inside a
disposable macOS VM* via RayMol's built-in MCP server.

## Problem / current state

RayMol's built-in MCP server ([`modules/raymol_mcp/server.py`](../../../modules/raymol_mcp/server.py))
is MCP "Streamable HTTP" (JSON-RPC 2.0 over HTTP POST to `/mcp`, single `application/json`
response). It is **hardcoded to bind `127.0.0.1`** (`server.py:230`). The host's MCP client
(`~/.claude.json` → `mcpServers.raymol`) points at `http://127.0.0.1:51737/mcp`.

Three factors decide whether the host can drive RayMol running in a mac-vm-test VM:

| Factor | Status |
|---|---|
| VM networking (host→VM reachability) | ✅ tart default NAT; VM on `192.168.64.x`, host `192.168.64.1`; host→VM to arbitrary ports routable (SSH/scp already work; verified live: ping to a running pool VM, 0% loss). |
| Transport (HTTP over TCP) | ✅ Crosses the VM boundary fine; host client speaks `--transport http`. |
| **Bind address** | ❌ **Blocker.** Server binds VM-loopback (`127.0.0.1`), unreachable from the host. |

**Verdict:** does not work today; one clean blocker (loopback bind).

## Design

Chosen: **Direct-HTTP driver** (host talks straight to the VM endpoint over HTTP; no MCP
client re-registration, which would hit the mid-session reconnection wall) + a **new
RayMol-repo skill** `.claude/skills/raymol-mac-vm/` (version-controlled, shipped in the PR;
builds on the mac-vm-test / mac-vm-pool flow but keeps RayMol specifics in the repo).

### Data flow

```
HOST (Claude Code session)                       VM (disposable clone, NAT 192.168.64.x)
.claude/skills/raymol-mac-vm/                     RayMol.app (direct-exec launch w/ dev env)
  ├─ SKILL.md   (orchestrates loop)                 └─ embedded Python raymol_mcp.server
  └─ raymol-vm-mcp.py (driver) ──HTTP POST /mcp──▶       ThreadingHTTPServer(("0.0.0.0", port))
        JSON-RPC 2.0 + Bearer token                       ↑ RAYMOL_MCP_BIND=0.0.0.0
  discovery: ssh admin@$IP cat mcp.json ──────────────────↑ RAYMOL_MCP_AUTOTRUST=1
        → {port, token}                                    ↑ RAYMOL_MCP_ENABLE=1
  VM IP from pool acquire_vm handle
```

### Components

**A. RayMol code (the enabling dev flags — in the PR)**
- `modules/raymol_mcp/server.py:230` — bind host from env:
  `bind_host = os.environ.get("RAYMOL_MCP_BIND") or "127.0.0.1"`, dev-only comment mirroring
  the `RAYMOL_MCP_AUTOTRUST` note above. **Single load-bearing change.** Default = loopback,
  unchanged for production.
- `swiftui/PyMOLViewer/Shared/MCPServerManager.swift` — `autoStartIfEnabled` also starts when
  `ProcessInfo…environment["RAYMOL_MCP_ENABLE"] == "1"`, so a fresh VM clone (UserDefault off)
  brings the server up headlessly. Already inside `#if os(macOS) && !RAYMOL_MAS_RESTRICTED`.

**B. `.claude/skills/raymol-mac-vm/raymol-vm-mcp.py`** — stdlib-only MCP-over-HTTP CLI:
`discover` (ssh-reads `~/Library/Application Support/RayMol/mcp.json`), `cmd`, `py`, `state`,
`capture <out.png>` (decodes base64 PNG to file), `search`, `register` (prints the
`claude mcp add --transport http raymol-vm …` line for native use in a fresh session).
Carries `Authorization: Bearer` + `Mcp-Session-Id`.

**C. `.claude/skills/raymol-mac-vm/SKILL.md`** — orchestration: acquire (pool MCP) → two-stage
host build (`build_macos.sh` core **then** xcodebuild — avoids the stale `libpymol_core.a`) →
scp app in → **direct-exec launch with the three env vars** (via `tart exec … env … RayMol`,
because `open`/Finder deliberately don't carry these vars) → discover → curl sanity-check →
drive via helper → **always release**.

### VM launch (env delivery)

The three `RAYMOL_MCP_*` vars must reach the GUI app's process. A plain `launchctl setenv` over
SSH does not reach the console Aqua session, so they're set in the console user's launchd domain
(needs root; passwordless sudo works on the golden image), then `open` launches the app:

```
ssh admin@$IP '
  CUID=$(id -u)
  sudo launchctl asuser $CUID launchctl setenv RAYMOL_MCP_BIND 0.0.0.0
  sudo launchctl asuser $CUID launchctl setenv RAYMOL_MCP_AUTOTRUST 1
  sudo launchctl asuser $CUID launchctl setenv RAYMOL_MCP_ENABLE 1
  open ~/Apps/RayMol.app'
```

**Verified 2026-07-04** (golden image macOS 15.7.7): the launched process carried all three vars,
the server bound `*:51737`, and the host drove `fetch 1ubq` → cartoon → ray-traced capture end to
end. (Direct-exec of the Mach-O with an `env` prefix is a plausible alternative but was not the
verified path.)

### Discovery

```
ssh -i ~/.mac-vm-pool/id_ed25519 admin@$IP \
  'cat "$HOME/Library/Application Support/RayMol/mcp.json"'   # → {port, token}
endpoint = http://$IP:$port/mcp     # $IP from the pool acquire handle
```

## Error handling
- `acquire_vm` → `{queued:true}`: report the 2-VM cap, stop.
- Build failure: surface output, release VM, do not proceed.
- Endpoint unreachable: helper distinguishes connection-refused (not bound wide / not started
  → check the three env vars), 401 (token mismatch), timeout (guest firewall — see open
  question). Diagnostic: `ssh … lsof -nP -iTCP:$port -sTCP:LISTEN`.
- VM release always runs, even on failure, after capturing an AX dump + screenshot.

## Security
`RAYMOL_MCP_BIND=0.0.0.0` is opt-in, dev-only, defaults to loopback. When set, the listener is
reachable only from the host and at most one sibling VM on the NAT (not LAN/internet), and
**every request still requires the bearer token** — no "trusted network skips auth" shortcut.
Direct-HTTP driving persists nothing to `~/.claude.json`, so there's no per-VM token to leak or
clean up. All new flags sit on the non-MAS side of `RAYMOL_MAS_RESTRICTED` (which already strips
the whole `raymol_mcp` package from App Store builds).

## Testing
- **server.py bind (headless, host):** `RAYMOL_MCP_BIND=0.0.0.0 python -c "import raymol_mcp.server as s; s.start(0,'tok')"` → `lsof` shows `*:port`; unset → `127.0.0.1:port`.
- **End-to-end acceptance (real VM):** acquire → build → launch → discover → `raymol-vm-mcp cmd "fetch 1ubq, async=0"` → `capture out.png` → verify PNG shows ubiquitin → release.
- **Open question (resolve on first e2e run):** golden-image guest firewall on an arbitrary high
  port. SSH:22 works, strongly implying inbound is open; the e2e curl settles it. If blocked, the
  fix is a `socketfilterfw`/`pfctl` allowance baked into the golden image — a mac-vm-pool change,
  out of this PR's scope.

## Out of scope
- iOS/iPadOS (MCP server is `#if os(macOS)`-gated).
- Switching the pool to `--net-softnet` with explicit port-expose (tighter isolation; pool change).
- Editing the generic, non-versioned `~/.claude/skills/mac-vm-test/SKILL.md`.
