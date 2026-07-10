# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A BeamNG.drive mod that drives the in-game free camera with a real smartphone's orientation, for handheld-style video recording. Pipeline:

```
phone browser (web/index.html)          — DeviceOrientation -> quaternion, WebSocket :8081
  -> relay server (server/relay_server.py) — dumb pipe, forwards verbatim as UDP :4444
    -> BeamNG GE Lua extension (beamng_mod/phonecam/lua/ge/extensions/phoneCamera.lua)
```

Remote: https://github.com/alexanderc45/phonecam

## Where the math lives (deliberate split)

- **Phone (JS)**: converts the Z-X'-Y'' Euler degrees from DeviceOrientation into a quaternion (three.js `DeviceOrientationControls` formula, screen-rotation compensated) in a **Y-up** three.js-style frame. Euler->quaternion happens here specifically to avoid gimbal handling in Lua.
- **Relay (Python)**: no math, no parsing. Forwards each WebSocket message unchanged as one UDP datagram. Keep it that way.
- **Lua**: converts Y-up -> BeamNG Z-up with a component swap `(x, y, z, w) -> (x, -z, y, w)`, then applies only the rotation **relative to the last recenter**: `target = camBase * refQuat^-1 * phoneQuat`, smoothed framerate-independently, written via `setCameraPosRot()` only while `commands.isFreeCamera()`.

Wire protocol (JSON text per datagram): `{"t":"o","q":[x,y,z,w],"a":...,"b":...,"g":...}` for orientation, `{"t":"recenter"}` to re-zero. If you change it, update all three components.

## Critical: derived artifacts that do NOT auto-update

- **`phonecam.zip`** (repo root) is the drag-and-drop packed mod users download from the README. After changing anything under `beamng_mod/phonecam/`, you MUST regenerate and commit it:
  ```powershell
  git archive --format=zip -o phonecam.zip HEAD:beamng_mod/phonecam
  ```
  (`git archive` from HEAD — commit the mod change first. Don't use `Compress-Archive`; its backslash entry paths are risky for non-Windows unzip code.)
- **`PhoneCamRelay.exe`**: built by `.github/workflows/build-exe.yml` (PyInstaller onefile, `web/` bundled via `--add-data`) and published to the rolling `latest` GitHub release on pushes to `master` touching `server/**`, `web/**`, or the workflow. The web client is **inside the exe** — a `web/index.html` change is invisible to users until the workflow rebuilds and they re-download.

## Commands

- Run the relay from source (Python 3.10+; note: Python is NOT installed on this dev laptop — CI is the only way to build/test the exe here):
  ```powershell
  pip install -r server\requirements.txt
  python server\relay_server.py [--http-port 8080] [--ws-port 8081] [--udp-host IP] [--udp-port 4444] [--cert c.pem --key k.pem]
  ```
- No test suite. The only automated check is the CI smoke test (starts the exe, asserts the "relay is running" banner appears in redirected stdout). Because of it, `relay_server.py` reconfigures stdout to line-buffered UTF-8 at startup — don't remove that.
- Watch a CI run / release without `gh` (not installed): poll `https://api.github.com/repos/alexanderc45/phonecam/actions/runs?per_page=1` unauthenticated.

## BeamNG mod specifics

- Loads as a GE extension via `scripts/phonecam/modScript.lua` (`extensions.load('phoneCamera')`, unload mode `manual` so it survives level reloads). LuaSocket comes bundled with BeamNG as `require('socket.socket')`; the UDP socket must stay non-blocking (`settimeout(0)`), draining all queued datagrams per frame and keeping only the newest orientation.
- In-game console API: `extensions.phoneCamera.recenter()` / `setEnabled(bool)` / `setSmoothing(seconds)` / `setPort(n)`.
- Install for testing: copy `beamng_mod/phonecam` to `%LOCALAPPDATA%\BeamNG.drive\<version>\mods\unpacked\`, or drop `phonecam.zip` into `mods\`.

## Repo conventions

- Git identity is intentionally repo-local `alexanderc45 <alexanderc45@users.noreply.github.com>` — the history was once rewritten and force-pushed to purge the owner's personal email. Never commit with a personal name/email here.
- Browser sensor access is the #1 user-facing failure mode: DeviceOrientation is blocked on insecure origins (Android needs the `chrome://flags/#unsafely-treat-insecure-origin-as-secure` workaround; iOS additionally requires HTTPS + a user-gesture `requestPermission()`). The web client detects and explains these itself — keep that behavior when editing it, and keep it fully self-contained (no CDN/external resources; phones on LAN may be offline).
