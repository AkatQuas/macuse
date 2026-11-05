# MacUse

**MacUse** is a native macOS Apple Silicon helper for [Computer Use](https://platform.openai.com/docs/guides/tools-computer-use)-style agents. A long-lived Swift service drives Accessibility (AX), ScreenCaptureKit, and synthetic input; a thin Node [Model Context Protocol (MCP)](https://modelcontextprotocol.io) bridge exposes the same tool surface to MCP clients. The design follows public CU tool semantics but does not depend on vendor installers, accounts, or private wire formats.

| | |
|---|---|
| **Platform** | macOS 14+, **arm64 only** |
| **App bundle** | `MacUse Helper` (menu-bar agent, no Dock icon) |
| **Wire protocol** | `MacUse-1` — length-prefixed JSON-RPC 2.0 on a Unix socket |
| **MCP server name** | `macuse` |

## Architecture

```text
Agent ── MCP stdio ── Node bridge (official MCP SDK)
                              │
                    Unix socket, framed JSON-RPC
                              │
                    Swift MacUse service
                     AX / ScreenCaptureKit / CGEvent
```

The native service stays up while clients connect and disconnect. Each TCP-style request uses its own connection; **`session_id`** groups snapshot state on the server. The MCP bridge generates a session UUID per process unless you set **`MACUSE_SESSION`** to reuse state across bridge restarts. State is not persisted after the service exits.

## Quick start (developers)

### 1. Run the helper app

Download **`MacUse-macos-arm64.zip`** from [GitHub Releases](https://github.com/AkatQuas/macuse/releases) (or build locally), unzip, then:

```sh
open -g "/path/to/MacUse Helper.app"
```

By default the app listens on `~/Library/Application Support/MacUse/cu.sock` and allowlists **Calculator** (`com.apple.calculator`). Grant **Accessibility** and **Screen Recording** when prompted (or via System Settings).

Trigger permission prompts from a fresh process instance:

```sh
open -n -g "/path/to/MacUse Helper.app" --args --request-permissions
```

**macOS 15 (Sequoia)** may show recurring alerts when MacUse captures via ScreenCaptureKit without Apple’s system sharing picker. MacUse intentionally keeps the **rc1-style programmatic capture** (Screen Recording + allowlisted window matching) so agents are not blocked on per-app picker flows. Integrators who need picker-only capture on Sequoia can wrap or fork the service; that tradeoff is documented, not enforced here.

**Stale socket after `kill -9`:** SIGTERM/SIGINT remove the socket on exit; SIGKILL does not. On startup, MacUse **probes** the path with a `ping` RPC—if a live service answers, startup fails; otherwise it **unlinks the orphaned socket** and binds.

Custom socket and allowlist (only when no live instance is already listening):

```sh
open -g "/path/to/MacUse Helper.app" --args serve \
  --socket /private/tmp/my-macuse/cu.sock \
  --allow-app com.apple.calculator
```

The socket parent directory must exist, be **chmod 700**, and be owned by you.

### 2. Connect the MCP bridge

```sh
cd bridge
npm ci
export MACUSE_SOCKET="$HOME/Library/Application Support/MacUse/cu.sock"
node server.mjs
```

Register the bridge in your MCP client: command `node`, args absolute path to `bridge/server.mjs`, env **`MACUSE_SOCKET`**. Optional **`MACUSE_SESSION`** is a caller-chosen local session id (not authentication).

**Tools:** `check_permissions`, `list_apps`, `list_displays`, `get_app_state`, `get_screenshot`, `get_display_screenshot`, `click`, `set_value`, `type_text`, `press_key`, `end_session`.

Legacy env names `NATIVE_CU_*` are still accepted by the bridge for compatibility with earlier prototypes.

### 3. Build from source

```sh
swift build
mkdir -m 700 /private/tmp/my-macuse
.build/debug/MacUse serve \
  --socket /private/tmp/my-macuse/cu.sock \
  --allow-app com.apple.calculator
```

Release app bundle:

```sh
./scripts/build-app.sh
```

Ad-hoc signing is the default (`MACUSE_SIGN_IDENTITY` unset). For distribution outside your machine, sign with a stable **Developer ID** and notarize separately.

## Integrating without MCP

Use the framed JSON-RPC protocol directly or the small Node client:

```js
import { rpc } from './bridge/rpc.mjs';

const result = await rpc(socketPath, 'tools/call', {
  session_id: 'agent-task-1',
  name: 'check_permissions',
  arguments: {},
});
```

**Ping:**

```json
{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}
```

**Tool call:**

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"session_id":"agent-task-1","name":"get_app_state","arguments":{"app":"com.apple.calculator"}}}
```

Responses include `app`, `pid`, `snapshot_id`, `state`, `truncated`. Mutating tools require the latest `app` and `snapshot_id`. Business failures use `result.isError`, `code`, and `message`; protocol errors use JSON-RPC `error`.

**Limits:** 1 MiB request / 24 MiB response, 30 s idle I/O timeout, 16 concurrent connections, 128 sessions, one UI mutation at a time (others get `busy`). Snapshots expire after 120 s and are invalidated when the window, PID, or geometry changes.

## Agent loop (recommended)

1. **`get_app_state`** — pick an allowlisted app; observe the AX tree (no screenshot by default).
2. **`click` / `set_value`** — use integer **`element_index`** from the tree; coordinate clicks need **`get_screenshot`** first.
3. After each mutation, use the **new** `snapshot_id` returned in the result.
4. On error, timeout, or cancel, **re-read state** before sending more input (in-flight OS events are not rolled back).
5. **`end_session`** when finished; the service keeps running for other tasks.

Optional **`get_display_screenshot`** (with **`list_displays`**) captures a full monitor for observation only; it does not replace allowlisted window snapshots for **`click`**. **Coordinate clicks** map through the ScreenCaptureKit window frame captured with the screenshot (not the AX rect alone). Actions activate the target app and may move the real cursor; there is no headless “invisible cursor” mode. Multi-display layouts and menu-bar offsets can still affect clicks — validate on your target setup.

The Unix socket accepts up to **16 concurrent connections**; additional clients wait up to **5 seconds** for a slot, then the connection closes.

## Security model

Trust boundary is the **current macOS user**: socket directory `0700`, socket owner-only, **`getpeereid`** requires same UID. **`session_id`** groups snapshots only; it is not isolation between local processes. Allowed apps are fixed at **`serve`** startup — there is no runtime approval UI.

## Verification

| Suite | Command | What it proves |
|--------|---------|----------------|
| Protocol | `swift build && node tests/protocol.mjs` | Framing, sessions, errors, cleanup (no GUI) |
| MCP boundary | `cd bridge && npm ci && node ../tests/mcp.mjs` | MCP schemas, forwarding, PNG mapping, reconnect (fixture socket, no TCC) |
| Swift E2E | `swiftc -parse-as-library tests/NativeE2E.swift -o .build/native-e2e && .build/native-e2e` | Real Calculator via the **App** (needs TCC; do not use the machine during the run) |

E2E env overrides: **`MACUSE_APP`**, **`MACUSE_SOCKET`**, **`MACUSE_E2E_OUTPUT`**.

CI on `macos-15` runs protocol and MCP tests, builds the signed app, and attaches **`MacUse-macos-arm64.zip`** plus **`SHA256SUMS.txt`** to GitHub Releases when you push a **`v*`** tag (including `-rc` prereleases). UI E2E is compiled in CI but executed only on a TCC-authorized Mac.

```sh
git tag v0.1.0-rc.1
git push origin v0.1.0-rc.1
```

## Repository layout

```text
Sources/MacUse/     Swift service
bridge/             MCP stdio server + rpc.mjs client
app/                Info.plist, MacUse.png (icon source)
scripts/build-app.sh
tests/              protocol.mjs, mcp.mjs, NativeE2E.swift
```

## Roadmap (non-goals today)

App Sandbox, OCR/ONNX/YOLO, scroll/drag, paste simulation, AX diffing, and native cancellation of in-flight UI actions are not implemented. Contributions welcome via issues and PRs.

## License

MIT — see [LICENSE](LICENSE).
