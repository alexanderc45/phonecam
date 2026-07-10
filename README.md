# BeamNG Phone Camera

Use your smartphone as a **virtual camera crane** for BeamNG.drive video recording. Move the phone in the real world — the in-game free camera rotates with it, streamed live at up to 60 Hz.

No mobile app required: the phone just opens a web page.

## ⚡ Quick install — two downloads, no tools required

1. **The mod:** [download phonecam.zip](https://github.com/alexanderc45/phonecam/raw/master/phonecam.zip) and drop it — **without unzipping** — into your BeamNG mods folder:
   - Current versions (0.32+): `%LOCALAPPDATA%\BeamNG.drive\<version>\mods\`
   - Older versions: `Documents\BeamNG.drive\<version>\mods\`
2. **The server:** [download PhoneCamRelay.exe](https://github.com/alexanderc45/phonecam/releases/latest/download/PhoneCamRelay.exe) (from [Releases](https://github.com/alexanderc45/phonecam/releases)) and double-click it. Python and the web client are bundled inside — nothing to install. It prints a QR code; scan it with your phone.

   > The exe is unsigned, so Windows SmartScreen may warn on first run — click **More info → Run anyway**. Allow it through the firewall prompt (private networks).
3. Start BeamNG, press **Shift+C** for free camera, tap **Start streaming** then **Recenter camera** on the phone. Done.

Prefer running from source instead of the exe? See [Run the relay server](#2-run-the-relay-server) below.

```
┌─────────┐  DeviceOrientation   ┌──────────────┐        UDP         ┌──────────────┐
│  Phone   │ ──── WebSocket ────▶ │ Relay server │ ──── (JSON) ─────▶ │ BeamNG.drive │
│ (browser)│      port 8081       │  (Python)    │     port 4444      │  (Lua mod)   │
└─────────┘                       └──────────────┘                    └──────────────┘
      ▲  loads web client over HTTP, port 8080  │
      └─────────────────────────────────────────┘
```

## Directory structure

```
beamng-phone-camera/
├── README.md
├── web/
│   └── index.html                  # phone web client (sensors -> quaternion -> WebSocket)
├── server/
│   ├── relay_server.py             # HTTP + WebSocket -> UDP relay
│   └── requirements.txt
└── beamng_mod/
    └── phonecam/                   # <- copy THIS folder into mods/unpacked/
        ├── mod_info.json
        ├── scripts/phonecam/modScript.lua        # loads the extension on startup
        └── lua/ge/extensions/phoneCamera.lua     # UDP listener + camera driver
```

## How the math works

1. **Phone (JS)** — the DeviceOrientation API reports intrinsic Z-X'-Y'' Euler angles in **degrees** (`alpha` yaw 0–360, `beta` pitch ±180, `gamma` roll ±90). Euler angles gimbal-flip near ±90°, so the client converts degrees → radians and builds a **quaternion** (the proven three.js `DeviceOrientationControls` formula), including screen-rotation compensation so portrait/landscape behave identically. The quaternion is what gets streamed.
2. **Relay (Python)** — a dumb pipe. Forwards each WebSocket message verbatim as a UDP datagram. UDP is intentional: a stale orientation frame is worthless, so no retransmission wanted.
3. **BeamNG (Lua)** — the phone quaternion arrives in a Y-up frame; BeamNG is Z-up. The change of basis reduces to a component swap: `(x, y, z, w) → (x, −z, y, w)`. The mod then applies only the **relative** rotation since the last "recenter" (`target = camBase * refQuat⁻¹ * phoneQuat`), smooths it with a framerate-independent exponential filter, and writes it to the free camera with `setCameraPosRot()` every frame.

Full derivations are in the comments of `web/index.html` and `phoneCamera.lua`.

## Setup

### 1. Install the BeamNG mod

Easiest: use the [Quick install zip](#-quick-install-zip) above. Alternatively (e.g. if you want to edit the Lua), copy `beamng_mod/phonecam` into your BeamNG **unpacked mods** folder:

- Current versions (0.32+): `%LOCALAPPDATA%\BeamNG.drive\<version>\mods\unpacked\phonecam`
- Older versions: `Documents\BeamNG.drive\<version>\mods\unpacked\phonecam`

(Create the `unpacked` folder if it doesn't exist.) Restart BeamNG, or enable the mod in the in-game Mods manager.

### 2. Run the relay server

**Option A — standalone exe (easiest):** [PhoneCamRelay.exe](https://github.com/alexanderc45/phonecam/releases/latest/download/PhoneCamRelay.exe), double-click, done. It's built automatically from `master` by GitHub Actions (`.github/workflows/build-exe.yml`), so it's always current. Command-line flags below work with the exe too (e.g. `PhoneCamRelay.exe --udp-host 192.168.1.50`).

**Option B — from source.** Requires Python 3.10+:

```powershell
pip install -r server\requirements.txt
python server\relay_server.py
```

Defaults: web client on **:8080**, WebSocket on **:8081**, UDP to **127.0.0.1:4444**. The console prints the exact URL to open on the phone.

Running the game on a **different PC** than the server? Point the UDP stream at it:

```powershell
python server\relay_server.py --udp-host <GAMING_PC_IP>
```

> **Windows Firewall:** allow inbound TCP 8080/8081 on the machine running the server (and UDP 4444 on the gaming PC if it's a separate machine). The first launch usually triggers the standard firewall prompt — click Allow.

### 3. Connect the phone

Phone and server machine must be on the **same Wi-Fi**. Open the printed URL (e.g. `http://192.168.1.23:8080`) and tap **Start streaming**.

**Sensor access caveats** — browsers restrict motion sensors on insecure (`http://`) origins:

- **Android / Chrome:** open `chrome://flags/#unsafely-treat-insecure-origin-as-secure`, add `http://<SERVER_IP>:8080`, relaunch Chrome. (Or use HTTPS below.)
- **iOS / Safari:** HTTPS is mandatory *and* a permission prompt appears on tap. Generate a self-signed certificate and run the server with TLS:

  ```powershell
  openssl req -x509 -newkey rsa:2048 -keyout server\key.pem -out server\cert.pem -days 365 -nodes -subj "/CN=beamng-phone-cam"
  python server\relay_server.py --cert server\cert.pem --key server\key.pem
  ```

  Then open `https://<SERVER_IP>:8080` and accept the certificate warning.

### 4. In the game

1. Load any map, press **Shift+C** to switch to the free camera.
2. Hold the phone in your intended neutral pose (landscape, like filming) and tap **Recenter camera** on the phone.
3. Move the phone — the camera follows. Use the game's normal WASD keys to move the camera position; the phone controls rotation only.

### Console commands (`~` in game)

| Command | Effect |
|---|---|
| `extensions.phoneCamera.recenter()` | re-zero phone pose to current camera pose |
| `extensions.phoneCamera.setEnabled(false)` | pause phone control |
| `extensions.phoneCamera.setSmoothing(0.15)` | smoothing time constant in seconds (default 0.06) |
| `extensions.phoneCamera.setPort(5555)` | change the UDP listen port |

## Development note

`phonecam.zip` is the packed build of `beamng_mod/phonecam/`. After changing any mod file, regenerate and commit it:

```powershell
git archive --format=zip -o phonecam.zip HEAD:beamng_mod/phonecam
```

## Troubleshooting

- **Page loads but no sensor data** → insecure-origin block; see the caveats in step 3.
- **Sensor data on phone but camera doesn't move** → make sure you're in **free camera** mode (Shift+C); check the BeamNG console for `phoneCamera` log lines; verify UDP port 4444 isn't blocked/in use.
- **Camera drifts or points the wrong way** → tap **Recenter camera** while holding the phone in your neutral filming pose. Cheap phone gyros drift over minutes; recenter as needed.
- **Jittery footage** → raise smoothing: `extensions.phoneCamera.setSmoothing(0.15)`.
