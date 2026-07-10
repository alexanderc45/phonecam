# BeamNG Phone Camera

Use your smartphone as a **virtual camera crane** for BeamNG.drive. Hold your phone like a real camera — the in-game view rotates *and* moves with it (full 6DOF), streamed live at ~60 Hz. Great for handheld-style chase shots, walk-arounds, and cinematics.

Head-look now works in **any camera mode** — orbit, hood, cab, chase, free — not just the free camera.

> **Status: beta.** The 6DOF (LOTA) path is freshly implemented and still being verified in-game; axis calibration for physical *movement* is being finalized, so up/down/strafe signs may need a tweak. Rotation is the stable part. Please report anything that looks mirrored or inverted.

## ⚡ Quick start (iOS, recommended) — no relay, no web page, no certs

1. **Install the mod.** [Download phonecam.zip](https://github.com/alexanderc45/phonecam/raw/master/phonecam.zip) and drop it — **without unzipping** — into your BeamNG mods folder:
   - Current versions (0.32+): `%LOCALAPPDATA%\BeamNG.drive\<version>\mods\`
   - Older versions: `Documents\BeamNG.drive\<version>\mods\`
2. **Install LOTA on your iPhone.** Get the free app **"LOTA — LiDAR Over the Air"** ([lidarota.app](https://lidarota.app), App Store, iOS 26.2+ — LiDAR is *not* required). In LOTA, set the transmission destination to your **gaming PC's LAN IP**, port **9000**.
3. **Play.** Start BeamNG, load a map, and start streaming from LOTA. The mod listens on UDP `:9000` out of the box — no server, no browser, no setup. Move and rotate your phone; the camera follows.

That's it. To re-zero the pose to your current camera, run `extensions.phoneCamera.recenter()` in the game console (`~`) while holding the phone in your neutral filming pose.

> No iPhone? A legacy browser-based path (any phone with a web browser) also works — see [Legacy web-client path](#legacy-web-client-path-no-iphone) below.

## Install

### Option A — drag-and-drop zip (easiest)

[Download phonecam.zip](https://github.com/alexanderc45/phonecam/raw/master/phonecam.zip) and drop the **zip itself** (don't unzip) into your BeamNG `mods\` folder (paths above). Restart BeamNG or enable it in the in-game Mods manager.

### Option B — unpacked folder (for editing the Lua)

Copy the `beamng_mod/phonecam` folder into your BeamNG **unpacked mods** folder:

- Current versions (0.32+): `%LOCALAPPDATA%\BeamNG.drive\<version>\mods\unpacked\phonecam`
- Older versions: `Documents\BeamNG.drive\<version>\mods\unpacked\phonecam`

(Create the `unpacked` folder if it doesn't exist.) Restart BeamNG or enable the mod in-game.

## Console commands (`~` in game)

| Command | Effect |
|---|---|
| `extensions.phoneCamera.recenter()` | re-zero phone pose to the current camera pose |
| `extensions.phoneCamera.setEnabled(false)` | pause phone control (`true` to resume) |
| `extensions.phoneCamera.setSmoothing(0.15)` | smoothing time constant in seconds (default `0.06`; bigger = smoother but laggier) |
| `extensions.phoneCamera.setPositionScale(2.0)` | scale physical movement (`1.0` = 1:1 meters) |
| `extensions.phoneCamera.setPositionEnabled(false)` | rotation only, ignore physical movement |
| `extensions.phoneCamera.setOscPort(9000)` | change the LOTA (OSC) listen port |
| `extensions.phoneCamera.setPort(4444)` | change the legacy JSON (relay) listen port |

**How movement behaves:** in the free camera (Shift+C) the phone rotates the view while WASD moves it. In every other camera mode, the phone adds a VR-style head-look on top of the game's camera. Real VR (OpenXR) always takes priority — the phone yields to your headset automatically.

## Troubleshooting

**LOTA (iOS) path:**

- **No camera movement at all** → make sure your iPhone granted LOTA the **Local Network** permission (iOS prompts once; if you dismissed it, enable it in Settings → LOTA). Confirm the destination IP is your **gaming PC's** LAN IP and the port is **9000**.
- **Stream stalls when you switch apps** → LOTA must stay in the **foreground**; iOS stops the camera stream when the app is backgrounded.
- **Nothing arrives on the PC** → phone and PC must be on the **same Wi-Fi** with **no VPN** active on either. On the PC, allow **inbound UDP 9000** through Windows Firewall.
- **View drifts or points slightly off** → hold the phone in your neutral pose and run `recenter()`. ARKit tracking can drift or pop on relocalization; re-zero as needed.
- **Movement feels mirrored/inverted** → known beta caveat (axis calibration in progress). Try `setPositionEnabled(false)` for rotation-only until it's finalized.
- **Jittery footage** → raise smoothing: `setSmoothing(0.15)`.

**Legacy web-client path:**

- **Page loads but no sensor data** → insecure-origin block; see the browser caveats in the legacy section below.
- **Sensor data on phone but camera doesn't move** → check the BeamNG console for `phoneCamera` log lines; verify UDP port 4444 isn't blocked or in use.
- **Camera drifts** → tap **Recenter camera** in the web client while holding the phone in your neutral pose.

## Legacy web-client path (no iPhone)

Any phone with a modern browser can drive the camera — **rotation only**, no app required — via a small relay server. This path has more setup friction (that's exactly why LOTA is now recommended), but it needs no App Store and works on Android.

1. **Run the relay server on your PC.** Easiest is the standalone [PhoneCamRelay.exe](https://github.com/alexanderc45/phonecam/releases/latest/download/PhoneCamRelay.exe) (from [Releases](https://github.com/alexanderc45/phonecam/releases)) — double-click it. Python and the web client are bundled inside; nothing to install. It prints a QR code and a URL.

   > The exe is unsigned, so Windows SmartScreen may warn on first run — click **More info → Run anyway**, and allow it through the firewall prompt (private networks).

2. **Open the web client on your phone.** Phone and PC must be on the **same Wi-Fi**. Open the printed URL (e.g. `http://192.168.1.23:8080`) and tap **Start streaming**, then **Recenter camera**.

3. **In the game**, press **Shift+C** for free camera (this path drives the free camera). Move the phone; the camera rotates.

**Browser sensor caveats** — browsers block motion sensors on insecure (`http://`) origins:

- **Android / Chrome:** open `chrome://flags/#unsafely-treat-insecure-origin-as-secure`, add `http://<PC_IP>:8080`, and relaunch Chrome. (Or use HTTPS below.)
- **iOS / Safari:** HTTPS is mandatory *and* a permission prompt appears on tap. Generate a self-signed certificate and run the relay with TLS:

  ```powershell
  openssl req -x509 -newkey rsa:2048 -keyout server\key.pem -out server\cert.pem -days 365 -nodes -subj "/CN=beamng-phone-cam"
  ```

  then start the relay with `--cert server\cert.pem --key server\key.pem` and open `https://<PC_IP>:8080`.

> **Windows Firewall (legacy path):** allow inbound TCP 8080/8081 on the PC running the relay (and UDP 4444 on the gaming PC if it's a separate machine).

Running the game on a **different PC** than the relay? Point the UDP stream at it: `PhoneCamRelay.exe --udp-host <GAMING_PC_IP>`.

*Android via a native ARCore app (6DOF, app-based, no browser flags) is planned.*

## How it works

Two input paths feed one in-game camera driver:

- **LOTA (iOS):** the app streams your phone's ARKit pose — **position + rotation, 6DOF** — as OSC messages over UDP directly to the mod on port **9000**, ~60 Hz. No relay, no browser.
- **Legacy web client:** the phone browser reads its DeviceOrientation sensors, builds a quaternion (rotation only), and streams it over WebSocket to a small Python relay, which forwards each frame verbatim as a UDP JSON datagram to the mod on port **4444**.

Inside BeamNG, the Lua extension converts the phone's Y-up pose into BeamNG's Z-up world, keeps only the **relative** pose since your last recenter, smooths it with a framerate-independent filter, and applies it. In the free camera it writes the pose directly; in every other mode it composes a head-look onto the active camera as a proper camera filter (yielding to OpenXR VR).

## Development notes

Only relevant to the **legacy relay** path.

- **Run the relay from source** (Python 3.10+):

  ```powershell
  pip install -r server\requirements.txt
  python server\relay_server.py [--http-port 8080] [--ws-port 8081] [--udp-host IP] [--udp-port 4444] [--cert c.pem --key k.pem]
  ```

  Defaults: web client on **:8080**, WebSocket on **:8081**, UDP to **127.0.0.1:4444**.

- **PhoneCamRelay.exe** is built automatically from `master` by GitHub Actions, with the web client bundled inside, so the release download is always current. A `web/` change reaches users only after the workflow rebuilds and they re-download.

- **`phonecam.zip`** is the packed build of the mod folder. After changing any mod file, regenerate and commit it:

  ```powershell
  git archive --format=zip -o phonecam.zip HEAD:beamng_mod/phonecam
  ```
