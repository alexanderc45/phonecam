-- ============================================================
-- BeamNG Phone Camera — GE Lua extension
--
-- Listens on local UDP ports (via BeamNG's bundled LuaSocket) for a
-- phone's camera pose, and exposes it to the rest of the mod:
--   * the phonelook.lua camera FILTER reads getHeadLookDelta()/getPosDelta()
--     and composes a VR-style head-look onto ANY active camera mode;
--   * this file also keeps the original free-camera writer (setCameraPosRot),
--     which owns the free camera only (the filter skips free cam).
--
-- ---- Two wire protocols on the same sockets -----------------
-- Datagrams are dispatched by their first byte:
--   '{'  -> legacy JSON   {"t":"o","q":[x,y,z,w]} / {"t":"recenter"}
--           (from web/index.html via the Python relay, UDP :4444)
--   '/'  -> OSC 1.0       LOTA (free iOS app) streams one message per
--           datagram, ~60 Hz, over UDP :9000:
--             /lota/camera/rotation ,ffff  quat x,y,z,w  (unit, big-endian)
--             /lota/camera/position ,fff   x,y,z meters  (big-endian)
--           (/lota/camera/euler, /lota/mode, /lota/fps are ignored)
--   '#'  -> OSC bundle    skipped defensively (LOTA sends no bundles)
-- Both listen sockets accept both protocols; two sockets exist only so
-- users don't have to change LOTA's default port.
--
-- ---- The interpretation model (rebuilt: per-axis, no quat chain) -----
-- We interpret the LOTA quaternion the SAME way a field-validated product
-- does: decompose the quat to Tait-Bryan Z-Y-X Euler angles, route each
-- angle to one camera axis (a fixed table), and track motion as a plain
-- per-axis difference from a captured neutral. There is NO gravity frame,
-- NO hold-mode/mirror correction, NO quaternion composition of deltas —
-- those fought sign/axis bugs for a day and are gone. Any residual axis
-- inversion is now a single named sign constant (SIGN_* below), flippable
-- from one in-game report.
--
--   decompose (radians, quat x,y,z,w):
--     aboutX = atan2(2*(w*x + y*z), 1 - 2*(x*x + y*y))
--     aboutY = asin(clamp(2*(w*y - z*x), -1, 1))
--     aboutZ = atan2(2*(w*z + x*y), 1 - 2*(y*y + z*z))
--   camera mapping (the load-bearing table):
--     camYaw   =  aboutY
--     camPitch =  aboutZ
--     camRoll  = -aboutX        (the ONLY rotation inversion)
--   position (raw px,py,pz meters, WORLD delta from neutral, no rotation):
--     camRight   =  (px - npx) * GAIN_X
--     camUp      =  (py - npy) * GAIN_Y
--     camForward = -(pz - npz) * GAIN_Z   (the ONLY position inversion)
--
-- ---- Recentering --------------------------------------------
-- The phone's absolute heading is meaningless in-game, so on "recenter"
-- we capture the current decomposed angles + raw position as the neutral;
-- every frame we apply only the per-axis DIFFERENCE since then. LOTA has
-- no phone-side recenter button; console recenter() covers it (and the
-- first sample auto-recenters so the view never snaps on connect).
-- ============================================================

local M = {}

local socket = require('socket.socket')   -- LuaSocket ships with BeamNG

-- isnaninf is an engine global; local fallback keeps this file safe to
-- syntax-check / reason about standalone.
local isnaninf = isnaninf or function(x) return x ~= x or x == math.huge or x == -math.huge end

-- ============================================================
-- IN-GAME SIGN CORRECTION — the only knobs you should ever need.
-- LOTA's raw angle/axis sign conventions relative to physical motion are
-- exactly what earlier builds fought; rather than bake a guess into the
-- math, each application sign is a named constant. If a single axis tracks
-- the wrong way in-game, flip its constant here (+1 <-> -1) and reload.
--   Rotation (applied to the smoothed per-axis deltas):
--     SIGN_YAW   -> +dYaw should turn the camera LEFT
--     SIGN_PITCH -> +dPitch should tilt the camera UP
--     SIGN_ROLL  -> +dRoll should roll the camera RIGHT
--   Position (applied to the smoothed camera-local offset):
--     SIGN_PX -> right, SIGN_PY -> forward, SIGN_PZ -> up
-- ============================================================
local SIGN_YAW   = 1
local SIGN_PITCH = 1
local SIGN_ROLL  = 1
local SIGN_PX    = 1
local SIGN_PY    = 1
local SIGN_PZ    = 1

-- Position gains (meters -> camera-local units before positionScale). From
-- the validated LOTA interpretation; camForward carries the only inversion.
local GAIN_X = 1.33   -- right
local GAIN_Y = 1.33   -- up
local GAIN_Z = 1.29   -- forward (paired with the -1 in the mapping)

-- Smoothing responses (per-channel EMA rate, 1/seconds-ish). alpha per
-- frame = min(1, dt * response); bigger = snappier. setSmoothing(seconds)
-- scales BOTH down for a smoother/laggier feel (see setSmoothing).
local ROTATION_RESPONSE    = 18.5
local TRANSLATION_RESPONSE = 34.8

-- Tunables ----------------------------------------------------
local listenHost = '127.0.0.1'   -- JSON relay runs on this PC
local listenPort = 4444
local oscHost    = '0.0.0.0'     -- LOTA streams from the phone over LAN
local oscPort    = 9000          -- LOTA default
local smoothingSeconds = 0.06    -- UI/console smoothing knob; scales the
                                 -- responses above (bigger = smoother/laggier)
local positionScale   = 1.0      -- meters -> world units multiplier
local positionEnabled = true     -- 6DOF translation on/off (filter path only)

-- setSmoothing maps its seconds argument to a single divisor applied to
-- both responses:  scale = max(0.02, seconds/0.06); response = base/scale.
-- At the 0.06 default scale == 1 (responses unchanged); doubling seconds
-- roughly halves the response (twice as smooth). Floored at 0.02 so the
-- slider's small end can't produce an absurd (>base) response.
local function smoothScale() return math.max(0.02, smoothingSeconds / 0.06) end
local function rotResponse()   return ROTATION_RESPONSE    / smoothScale() end
local function transResponse() return TRANSLATION_RESPONSE / smoothScale() end

-- State -------------------------------------------------------
local udp = nil             -- JSON listen socket (:listenPort)
local udpOsc = nil          -- OSC  listen socket (:oscPort)
local enabled = true

local lastRawQuat = nil     -- latest raw quat {x,y,z,w} (LOTA or JSON), unit
local camYaw, camPitch, camRoll = 0, 0, 0   -- latest mapped angles (radians)
local rawPhonePos = nil     -- latest phone position {x,y,z}, raw meters

local hasNeutral = false    -- has a recenter captured a reference yet?
local neutralYaw, neutralPitch, neutralRoll = 0, 0, 0
local neutralPos = nil      -- {x,y,z} captured at recenter (may be nil pre-position)

-- Per-channel smoothed deltas (nil = snap to first sample after recenter).
local smYaw, smPitch, smRoll = nil, nil, nil
local smRight, smForward, smUp = nil, nil, nil

local camBase = nil         -- free-cam orientation captured at recenter
local pendingRecenter = false
local packetsSeen = 0

-- Per-kind datagram counters for extensions.phoneCamera.debug()
local stats = { json = 0, osc = 0, oscRot = 0, oscPos = 0, oscOther = 0, other = 0 }
-- Rotation-parse failure forensics: why each rotation datagram was
-- rejected, plus a raw sample of the last failure for offline analysis.
local rotFails = { tags = 0, short = 0, nonfinite = 0, norm = 0 }
-- Heartbeats from the phonelook camera filter (proves core_camera runs it)
local filterStats = { tick = 0, applied = 0 }
local lastRotRaw = nil        -- first 64 bytes of the last failing datagram
local lastRotInfo = nil       -- human-readable decode of the last failure

-- ---- Recenter stability gate & stream-gap re-arm ----------------------
-- (Kept from the previous build — it operates on lastRawQuat only and is UX
-- we want.) Root cause of session-to-session axis inconsistency: recenter
-- used to fire on the FIRST packet — whatever pose the phone was in while the
-- user tapped LOTA's shutter (usually pointed at the floor/desk). Now a
-- pending recenter only executes once the phone is (a) roughly level (view
-- axis within ~45deg of horizontal) and (b) held steady (< ~20deg/s) for
-- STABLE_HOLD_S. The gate's view-axis check reads the raw quat directly with
-- VIEW_AXIS_DEV = (0,0,-1) (LOTA's device -z is the lens).
local VIEW_AXIS_DEV = { 0, 0, -1 }
local STABLE_HOLD_S = 0.7
local prevRawQuat = nil       -- previous rotation sample (rate estimation)
local lastUnstableClock = nil -- frameClock when the pose was last unstable
local recenterDeferLogged = false
-- Self-healing: a SUSTAINED unstable episode (phone stowed in a lap/pocket,
-- pointed at the floor, waved around for > STOW_REARM_S) re-arms the recenter
-- automatically — ARKit's tracking drifts/jumps when the camera is covered,
-- so the old reference is garbage after a stow.
local STOW_REARM_S = 2.0
local unstableSince = nil     -- frameClock when the current unstable episode began
local forceRecenter = false   -- setNeutral(): explicit intent bypasses the gate
local lastRotClock = nil      -- frameClock at last rotation packet; a >2s gap
                              -- in the stream triggers auto-recenter

-- Real-time seconds accumulated from onUpdate's dtReal. Used only as the
-- clock for the UI app's live-rate math (dtReal is always available here).
local frameClock = 0
-- Previous counter snapshot for M.getUiStatus() rate computation.
local uiRatePrev = nil

-- Rotate vector v = {x,y,z} by unit quaternion q = {x,y,z,w}: v' = q v q^-1.
-- Plain-table math (no engine types). Used ONLY by the stability gate.
local function qRotateVec(q, vx, vy, vz)
  local qx, qy, qz, qw = q[1], q[2], q[3], q[4]
  local tx = 2 * (qy*vz - qz*vy)
  local ty = 2 * (qz*vx - qx*vz)
  local tz = 2 * (qx*vy - qy*vx)
  return vx + qw*tx + (qy*tz - qz*ty),
         vy + qw*ty + (qz*tx - qx*tz),
         vz + qw*tz + (qx*ty - qy*tx)
end

-- ---- Rotation interpretation -----------------------------------------
-- Bring an angle difference into (-pi, pi] (shortest signed arc). Used on
-- every per-axis delta so a wrap past +/-180 never spins the camera around.
local function unwrap(a)
  while a > math.pi do a = a - 2 * math.pi end
  while a <= -math.pi do a = a + 2 * math.pi end
  return a
end

-- Decompose a unit quat {x,y,z,w} to Tait-Bryan Z-Y-X Euler and map each
-- angle to a camera channel. Single source of truth for BOTH wire paths.
local function updateAnglesFromRaw()
  if not lastRawQuat then return end
  local x, y, z, w = lastRawQuat[1], lastRawQuat[2], lastRawQuat[3], lastRawQuat[4]
  local aboutX = math.atan2(2 * (w*x + y*z), 1 - 2 * (x*x + y*y))
  local sinY = 2 * (w*y - z*x)
  if sinY > 1 then sinY = 1 elseif sinY < -1 then sinY = -1 end
  local aboutY = math.asin(sinY)
  local aboutZ = math.atan2(2 * (w*z + x*y), 1 - 2 * (y*y + z*z))
  camYaw   =  aboutY
  camPitch =  aboutZ
  camRoll  = -aboutX
end

-- Raw (unsmoothed) per-axis rotation deltas since neutral, or nil.
local function rawAngleDeltas()
  if not hasNeutral then return nil end
  return unwrap(camYaw - neutralYaw),
         unwrap(camPitch - neutralPitch),
         unwrap(camRoll - neutralRoll)
end

-- Raw (unsmoothed) camera-local position deltas since neutral (right,
-- forward, up in meters * gains), or nil.
local function rawPosDeltas()
  if not neutralPos or not rawPhonePos then return nil end
  local camRight   =  (rawPhonePos[1] - neutralPos[1]) * GAIN_X
  local camUp      =  (rawPhonePos[2] - neutralPos[2]) * GAIN_Y
  local camForward = -(rawPhonePos[3] - neutralPos[3]) * GAIN_Z
  return camRight, camForward, camUp
end

-- Quaternion for a rotation of `angle` radians about a camera-local axis.
-- BeamNG camera axes: x=right, y=forward, z=up.
local function quatAxis(ax, ay, az, angle)
  local h = angle * 0.5
  local s = math.sin(h)
  return quat(ax * s, ay * s, az * s, math.cos(h))
end

-- ---- Big-endian float32 decode (no string.unpack on LuaJIT) ----------
-- LuaJIT ffi fast path: write the 4 bytes reversed into a byte buffer
-- aliased as a float. Assumes a little-endian host (x86-64 / Apple silicon).
local ffi_ok, ffi = pcall(require, 'ffi')
local ffiBuf, ffiFloatPtr
if ffi_ok and ffi then
  local ok = pcall(function()
    ffiBuf = ffi.new('uint8_t[4]')
    ffiFloatPtr = ffi.cast('float*', ffiBuf)
  end)
  if not ok then ffiBuf, ffiFloatPtr = nil, nil end
end
-- Self-test: BeamNG's sandboxed GE Lua exposes a STUB ffi whose cast is a
-- no-op — indexing then returns the raw byte instead of the aliased float.
-- Decode 1.0f (big-endian 3f 80 00 00); if the fast path lies, disable it.
if ffiFloatPtr then
  ffiBuf[0] = 0x00; ffiBuf[1] = 0x00; ffiBuf[2] = 0x80; ffiBuf[3] = 0x3f
  local probe = tonumber(ffiFloatPtr[0])
  if probe ~= 1.0 then
    ffiBuf, ffiFloatPtr = nil, nil
    log('W', 'phoneCamera', 'ffi float decode unavailable/stubbed; using pure-Lua decoder')
  end
end

-- Pure-Lua IEEE-754 single-precision decode (fallback if ffi is absent).
local function ieee754BE(b1, b2, b3, b4)
  local sign = 1
  if b1 >= 128 then sign = -1; b1 = b1 - 128 end
  local exponent = b1 * 2 + math.floor(b2 / 128)
  local mantissa = ((b2 % 128) * 256 + b3) * 256 + b4
  if exponent == 0 then
    if mantissa == 0 then return 0.0 end
    return sign * mantissa * (2 ^ -149)              -- subnormal
  elseif exponent == 255 then
    if mantissa == 0 then return sign * math.huge end
    return 0 / 0                                     -- NaN
  end
  return sign * (1 + mantissa * (2 ^ -23)) * (2 ^ (exponent - 127))
end

-- Read a big-endian float32 from string s at 1-based byte offset off.
local function readFloatBE(s, off)
  local b1, b2, b3, b4 = string.byte(s, off, off + 3)
  if not b4 then return nil end
  if ffiFloatPtr then
    ffiBuf[0] = b4; ffiBuf[1] = b3; ffiBuf[2] = b2; ffiBuf[3] = b1
    return ffiFloatPtr[0]
  end
  return ieee754BE(b1, b2, b3, b4)
end

-- ---- Sample bookkeeping ---------------------------------------------
-- Auto-recenter on the very first pose sample so the camera doesn't jump
-- when the phone connects.
local function onFirstSample()
  packetsSeen = packetsSeen + 1
  if packetsSeen == 1 then pendingRecenter = true end
end

-- Ingest a rotation sample (already 4 finite components) from EITHER wire
-- path: normalize, store as lastRawQuat, decompose+map to camYaw/Pitch/Roll.
-- Returns true on success, false if the quat is degenerate.
local function ingestRotation(x, y, z, w)
  local n2 = x*x + y*y + z*z + w*w
  if isnaninf(n2) or n2 < 1e-6 then return false end
  local inv = 1 / math.sqrt(n2)
  lastRawQuat = { x * inv, y * inv, z * inv, w * inv }
  updateAnglesFromRaw()
  return true
end

-- ---- JSON path (legacy web client via relay) -------------------------
-- Behavior change (intentional, keeps one code path): the JSON quat now
-- goes through the SAME euler decomposition + mapping as LOTA. The JSON
-- path carries no stability data, so its recenter fires immediately.
local function handleJson(data)
  local msg = jsonDecode(data)
  if not msg then return end
  if msg.t == 'o' and type(msg.q) == 'table' and #msg.q == 4 then
    if ingestRotation(msg.q[1], msg.q[2], msg.q[3], msg.q[4]) then
      onFirstSample()
    end
  elseif msg.t == 'recenter' then
    pendingRecenter = true
  end
end

-- ---- OSC path (LOTA) -------------------------------------------------
-- OSC 1.0 layout: null-terminated address padded to 4, then the type-tag
-- string (","+tags, null-terminated, padded to 4), then big-endian args.
local function handleOsc(data)
  local addrEnd = data:find('\0', 1, true)     -- index of address's null
  if not addrEnd then return end
  local addr = data:sub(1, addrEnd - 1)
  local isRot = (addr == '/lota/camera/rotation')
  local isPos = (addr == '/lota/camera/position')
  if not (isRot or isPos) then stats.oscOther = stats.oscOther + 1; return end

  local tagPos = math.ceil(addrEnd / 4) * 4 + 1 -- start of type-tag string
  if data:byte(tagPos) ~= 44 then return end    -- 44 == ',' ; malformed otherwise
  local tagEnd = data:find('\0', tagPos, true)
  if not tagEnd then return end
  local tags = data:sub(tagPos + 1, tagEnd - 1) -- tags without the comma
  local argPos = tagPos + math.ceil((tagEnd - tagPos + 1) / 4) * 4

  if isRot then
    if tags ~= 'ffff' then
      rotFails.tags = rotFails.tags + 1
      lastRotRaw = data:sub(1, 64)
      lastRotInfo = string.format('tags=%q argPos=%d len=%d', tags, argPos, #data)
      return
    end
    local x = readFloatBE(data, argPos)
    local y = readFloatBE(data, argPos + 4)
    local z = readFloatBE(data, argPos + 8)
    local w = readFloatBE(data, argPos + 12)
    if not (x and y and z and w) then
      rotFails.short = rotFails.short + 1
      lastRotRaw = data:sub(1, 64)
      lastRotInfo = string.format('short read at argPos=%d len=%d', argPos, #data)
      return
    end
    if isnaninf(x) or isnaninf(y) or isnaninf(z) or isnaninf(w) then
      rotFails.nonfinite = rotFails.nonfinite + 1
      lastRotRaw = data:sub(1, 64)
      lastRotInfo = string.format('nonfinite: %g %g %g %g', x, y, z, w)
      return
    end
    local n2 = x*x + y*y + z*z + w*w
    -- reject junk; tolerate small drift then normalize (reject if
    -- |norm^2 - 1| > 0.1).
    if isnaninf(n2) or n2 < 1e-6 or math.abs(n2 - 1) > 0.1 then
      rotFails.norm = rotFails.norm + 1
      lastRotRaw = data:sub(1, 64)
      lastRotInfo = string.format('norm2=%.6f from %g %g %g %g', n2, x, y, z, w)
      return
    end
    ingestRotation(x, y, z, w)  -- sets lastRawQuat + camYaw/Pitch/Roll

    -- Console-free re-zero: a gap in the stream (LOTA toggled off/on, app
    -- backgrounded) means the user repositioned — re-derive the reference.
    if lastRotClock and (frameClock - lastRotClock) > 2 then
      pendingRecenter = true
      recenterDeferLogged = false
    end

    -- Stability tracking for the recenter gate: mark the pose unstable if
    -- it is rotating fast or the view axis is near-vertical (floor/ceiling).
    do
      local unstable = false
      if prevRawQuat then
        local dt = frameClock - (lastRotClock or frameClock)
        local dot = math.abs(lastRawQuat[1]*prevRawQuat[1] + lastRawQuat[2]*prevRawQuat[2]
                           + lastRawQuat[3]*prevRawQuat[3] + lastRawQuat[4]*prevRawQuat[4])
        local ang = 2 * math.acos(math.min(1, dot))
        if dt > 1e-4 and (ang / dt) > 0.35 then unstable = true end  -- > ~20 deg/s
      end
      local iq = { -lastRawQuat[1], -lastRawQuat[2], -lastRawQuat[3], lastRawQuat[4] }
      local ux, uy, uz = qRotateVec(iq, 0, 1, 0)
      local vdot = ux*VIEW_AXIS_DEV[1] + uy*VIEW_AXIS_DEV[2] + uz*VIEW_AXIS_DEV[3]
      if math.abs(vdot) > 0.7 then unstable = true end  -- view within ~45deg of vertical
      if unstable or not lastUnstableClock then lastUnstableClock = frameClock end
      if unstable then
        if not unstableSince then unstableSince = frameClock end
        if (frameClock - unstableSince) > STOW_REARM_S and not pendingRecenter then
          pendingRecenter = true
          recenterDeferLogged = false
          log('I', 'phoneCamera', 'phone stowed/unsteady - frame will re-lock on the next steady hold')
        end
      else
        unstableSince = nil
      end
      prevRawQuat = lastRawQuat
    end
    lastRotClock = frameClock

    stats.oscRot = stats.oscRot + 1
    if stats.oscRot == 1 then print('phoneCamera: first OSC rotation received - phone is live') end
    onFirstSample()
  else -- isPos
    if tags ~= 'fff' then return end
    local x = readFloatBE(data, argPos)
    local y = readFloatBE(data, argPos + 4)
    local z = readFloatBE(data, argPos + 8)
    if not (x and y and z) then return end
    if isnaninf(x) or isnaninf(y) or isnaninf(z) then return end
    rawPhonePos = { x, y, z }                  -- raw meters; delta'd in getPosDelta
    if not neutralPos then neutralPos = { x, y, z } end  -- auto-center first sample
    stats.oscPos = stats.oscPos + 1
    onFirstSample()
  end
end

-- Dispatch one datagram by its first byte (see header). Wrapped by the
-- caller in pcall so a single malformed packet can never crash the frame.
local function handleDatagram(data)
  if not data or #data == 0 then return end
  local c = string.byte(data, 1)
  if c == 123 then          -- '{'  JSON
    stats.json = stats.json + 1
    handleJson(data)
  elseif c == 47 then       -- '/'  OSC message
    stats.osc = stats.osc + 1
    handleOsc(data)
  else                      -- '#' OSC bundle or unknown: counted, ignored
    stats.other = stats.other + 1
  end
end

-- ---- Sockets ---------------------------------------------------------
local function openJsonSocket()
  if udp then udp:close() end
  udp = socket.udp()
  udp:setsockname(listenHost, listenPort)
  udp:settimeout(0)  -- non-blocking: never stall the render thread
  log('I', 'phoneCamera', string.format('JSON listening on UDP %s:%d', listenHost, listenPort))
end

local function openOscSocket()
  if udpOsc then udpOsc:close() end
  udpOsc = socket.udp()
  udpOsc:setsockname(oscHost, oscPort)
  udpOsc:settimeout(0)  -- non-blocking
  log('I', 'phoneCamera', string.format('OSC (LOTA) listening on UDP %s:%d', oscHost, oscPort))
end

-- Drain every datagram queued on one socket since last frame; only the
-- newest pose matters (older samples are stale), but recenter requests
-- inside the JSON stream must never be dropped, so we process each.
local function drainSocket(sock)
  if not sock then return end
  for _ = 1, 256 do
    local data = sock:receive()
    if not data then break end
    local ok, err = pcall(handleDatagram, data)
    if not ok then
      log('W', 'phoneCamera', 'dropped malformed datagram: ' .. tostring(err))
    end
  end
end

-- ---- Public accessors used by the phonelook filter -------------------
M.isEnabled = function() return enabled end

-- Heartbeat sink for the phonelook filter (debug instrumentation).
M._filterTick = function(kind)
  filterStats[kind] = (filterStats[kind] or 0) + 1
end

-- Smoothed camera-local head-look delta quat for phonelook.lua. Built from
-- the per-axis smoothed angle deltas:
--   q = qAboutZ(dYaw) * qAboutX(dPitch) * qAboutY(dRoll)
-- in BeamNG camera axes (x=right, y=forward, z=up): yaw about +z, pitch
-- about +x, roll about +y. Each channel carries its SIGN_* constant so a
-- residual inversion is a one-line fix. Returns nil when disabled / no data.
M.getHeadLookDelta = function(dtReal)
  if not enabled then return nil end
  local dy, dp, dr = rawAngleDeltas()
  if not dy then return nil end
  local a = math.min(1, (dtReal or 0.016) * rotResponse())
  smYaw   = smYaw   and (smYaw   + (dy - smYaw)   * a) or dy
  smPitch = smPitch and (smPitch + (dp - smPitch) * a) or dp
  smRoll  = smRoll  and (smRoll  + (dr - smRoll)  * a) or dr
  local qYaw   = quatAxis(0, 0, 1, smYaw   * SIGN_YAW)    -- +z
  local qPitch = quatAxis(1, 0, 0, smPitch * SIGN_PITCH)  -- +x
  local qRoll  = quatAxis(0, 1, 0, smRoll  * SIGN_ROLL)   -- +y
  local q = qYaw * qPitch * qRoll
  if isnaninf(q:squaredNorm()) then return nil end
  return q
end

-- Smoothed camera-local position delta vec3 for phonelook.lua, in BeamNG
-- camera-local axes (x=right, y=forward, z=up), scaled by positionScale.
M.getPosDelta = function(dtReal)
  if not enabled or not positionEnabled then return nil end
  local cr, cf, cu = rawPosDeltas()
  if not cr then return nil end
  local a = math.min(1, (dtReal or 0.016) * transResponse())
  smRight   = smRight   and (smRight   + (cr - smRight)   * a) or cr
  smForward = smForward and (smForward + (cf - smForward) * a) or cf
  smUp      = smUp      and (smUp      + (cu - smUp)      * a) or cu
  local v = vec3(smRight * SIGN_PX, smForward * SIGN_PY, smUp * SIGN_PZ) * positionScale
  if isnaninf(v:squaredLength()) then return nil end
  return v
end

-- ---- Per-frame ------------------------------------------------------
local function onExtensionLoaded()
  openJsonSocket()
  openOscSocket()
  log('I', 'phoneCamera', 'loaded. Head-look composes onto ANY camera mode via the phonelook filter;')
  log('I', 'phoneCamera', 'the free camera (Shift+C) still uses the legacy writer. Stream from your phone.')
  log('I', 'phoneCamera', 'console: extensions.phoneCamera.recenter() / setEnabled(bool) / setSmoothing(s) /')
  log('I', 'phoneCamera', '         setPort(n) / setOscPort(n) / setPositionScale(n) / setPositionEnabled(bool)')
end

local function onExtensionUnloaded()
  if udp then udp:close(); udp = nil end
  if udpOsc then udpOsc:close(); udpOsc = nil end
end

-- Capture the current pose as the neutral reference (rotation + position),
-- reset the smoothing state, and snapshot the free-cam base if active.
local function applyRecenter()
  updateAnglesFromRaw()          -- ensure angles match lastRawQuat
  neutralYaw, neutralPitch, neutralRoll = camYaw, camPitch, camRoll
  hasNeutral = true
  neutralPos = rawPhonePos and { rawPhonePos[1], rawPhonePos[2], rawPhonePos[3] } or nil
  smYaw, smPitch, smRoll = nil, nil, nil
  smRight, smForward, smUp = nil, nil, nil
  if commands.isFreeCamera() then
    camBase = getCameraQuat()    -- same frame as neutral so the view never snaps
  else
    camBase = nil                -- capture on entry to free cam instead
  end
  log('I', 'phoneCamera', 'recentered: current phone pose is now the reference')
end

local function onUpdate(dtReal)
  frameClock = frameClock + (dtReal or 0)   -- real-time base for UI rates
  drainSocket(udp)
  drainSocket(udpOsc)

  -- A pending recenter waits for the stability gate: phone roughly level and
  -- steady for STABLE_HOLD_S. JSON path has no stability data
  -- (lastUnstableClock stays nil) — treat it as immediately stable.
  local recenterReady = forceRecenter
      or (lastUnstableClock == nil)
      or ((frameClock - lastUnstableClock) >= STABLE_HOLD_S)
  if pendingRecenter and lastRawQuat and not recenterReady and not recenterDeferLogged then
    recenterDeferLogged = true
    print('phoneCamera: recenter armed - hold the phone level and steady to lock the frame')
  end
  if pendingRecenter and lastRawQuat and recenterReady then
    pendingRecenter = false
    forceRecenter = false
    recenterDeferLogged = false
    applyRecenter()
  end

  if not enabled or not lastRawQuat then return end

  -- Legacy free-cam writer. Only drives the free camera; every other mode is
  -- handled by the phonelook filter (which early-returns on free cam, so no
  -- double-apply). Rotation-only. Now shares getHeadLookDelta so the free cam
  -- and the filter use ONE interpretation.
  if not commands.isFreeCamera() then return end
  if not hasNeutral then return end
  if not camBase then camBase = getCameraQuat() end  -- entered free cam post-recenter
  local delta = M.getHeadLookDelta(dtReal)
  if not delta then return end
  local target = camBase * delta
  local pos = getCameraPosition()
  setCameraPosRot(pos.x, pos.y, pos.z, target.x, target.y, target.z, target.w)
end

-- Public API (console: extensions.phoneCamera.<fn>) ------------
M.recenter = function() pendingRecenter = true end

-- Explicit "this pose is my neutral": captures the CURRENT pose as the
-- baseline immediately, bypassing the stability gate. Wired to the UI button.
M.setNeutral = function()
  pendingRecenter = true
  forceRecenter = true
  log('I', 'phoneCamera', 'setNeutral: capturing current pose as the baseline')
end

-- Degrees; magnitude of the raw per-axis rotation delta since neutral
-- (sqrt(dYaw^2 + dPitch^2 + dRoll^2)). Shared by debug() and getUiStatus().
local function deltaAngleDeg()
  local dy, dp, dr = rawAngleDeltas()
  if not dy then return nil end
  return math.sqrt(dy*dy + dp*dp + dr*dr) * 180 / math.pi
end

-- One-shot status dump via print().
M.debug = function()
  print('phoneCamera status:')
  print(string.format('  enabled=%s positionEnabled=%s scale=%.2f smoothing=%.3fs (rotResp=%.1f transResp=%.1f)',
    tostring(enabled), tostring(positionEnabled), positionScale, smoothingSeconds, rotResponse(), transResponse()))
  print(string.format('  sockets: json=%s:%d (%s)  osc=%s:%d (%s)',
    listenHost, listenPort, udp and 'open' or 'CLOSED',
    oscHost, oscPort, udpOsc and 'open' or 'CLOSED'))
  print(string.format('  datagrams: json=%d osc=%d (rot=%d pos=%d other=%d) unknown=%d',
    stats.json, stats.osc, stats.oscRot, stats.oscPos, stats.oscOther, stats.other))
  print(string.format('  pose: rawQuat=%s phonePos=%s neutral=%s neutralPos=%s pendingRecenter=%s',
    lastRawQuat and 'yes' or 'NO', rawPhonePos and 'yes' or 'NO',
    hasNeutral and 'yes' or 'NO', neutralPos and 'yes' or 'NO', tostring(pendingRecenter)))
  print(string.format('  camera: isFreeCamera=%s', tostring(commands.isFreeCamera())))
  print(string.format('  rotFails: tags=%d short=%d nonfinite=%d norm=%d',
    rotFails.tags, rotFails.short, rotFails.nonfinite, rotFails.norm))
  print(string.format('  filter: tick=%d applied=%d  phonelookFile=%s',
    filterStats.tick, filterStats.applied,
    tostring(FS:fileExists('/lua/ge/extensions/core/cameraModes/phonelook.lua'))))
  print(string.format('  angles (deg): yaw=%.1f pitch=%.1f roll=%.1f',
    camYaw*180/math.pi, camPitch*180/math.pi, camRoll*180/math.pi))
  local dy, dp, dr = rawAngleDeltas()
  if dy then
    print(string.format('  delta since neutral (deg): dYaw=%.1f dPitch=%.1f dRoll=%.1f  (mag %.1f)',
      dy*180/math.pi, dp*180/math.pi, dr*180/math.pi, deltaAngleDeg() or 0))
  end
  local cr, cf, cu = rawPosDeltas()
  if cr then
    print(string.format('  posDelta since neutral (cam-local): right=%.3f fwd=%.3f up=%.3f (pre-scale)', cr, cf, cu))
  end
  if lastRotInfo then print('  lastRotFail: ' .. lastRotInfo) end
  if lastRotRaw then
    local hex = {}
    for i = 1, #lastRotRaw do hex[i] = string.format('%02x', lastRotRaw:byte(i)) end
    print('  lastRotRaw: ' .. table.concat(hex))
  end
end

-- Single flat snapshot for the in-game UI app. Mirrors debug() but returns
-- ONE table (encodeJson'd by the bngApi bridge) plus live per-second rates.
-- Nil-safe so the app can poll before/while the phone is connected.
M.getUiStatus = function()
  local now = frameClock

  local rotTotal = stats.json + stats.oscRot
  local rotRate, appliedRate, tickRate = 0, 0, 0
  if uiRatePrev then
    local dt = now - uiRatePrev.t
    if dt > 1e-3 then
      rotRate     = (rotTotal - uiRatePrev.rot) / dt
      appliedRate = (filterStats.applied - uiRatePrev.applied) / dt
      tickRate    = (filterStats.tick - uiRatePrev.tick) / dt
    else
      rotRate     = uiRatePrev.rotRate or 0
      appliedRate = uiRatePrev.appliedRate or 0
      tickRate    = uiRatePrev.tickRate or 0
    end
  end
  uiRatePrev = {
    t = now, rot = rotTotal, applied = filterStats.applied, tick = filterStats.tick,
    rotRate = rotRate, appliedRate = appliedRate, tickRate = tickRate,
  }

  local posDelta = nil
  local cr, cf, cu = rawPosDeltas()
  if cr then posDelta = { x = cr, y = cf, z = cu } end

  return {
    enabled = enabled,
    positionEnabled = positionEnabled,
    positionScale = positionScale,
    smoothingTau = smoothingSeconds,     -- UI slider reads this (seconds)
    -- Inert legacy fields (the per-axis mapping removed hold/mirror/calib);
    -- kept so the existing UI bindings/buttons don't error.
    holdMode = 0,
    mirrorRotation = false,
    calibStep = 0,
    calibrated = true,
    gripAuto = false,

    jsonHost = listenHost, jsonPort = listenPort, jsonOpen = udp ~= nil,
    oscHost = oscHost,     oscPort = oscPort,      oscOpen = udpOsc ~= nil,

    -- Per-kind datagram totals.
    dgJson = stats.json,
    dgOsc = stats.osc,
    dgOscRot = stats.oscRot,
    dgOscPos = stats.oscPos,
    dgOscOther = stats.oscOther,
    dgUnknown = stats.other,

    -- Rotation-parse failure forensics.
    rotFailsTags = rotFails.tags,
    rotFailsShort = rotFails.short,
    rotFailsNonfinite = rotFails.nonfinite,
    rotFailsNorm = rotFails.norm,
    rotFailsTotal = rotFails.tags + rotFails.short + rotFails.nonfinite + rotFails.norm,

    -- Camera filter heartbeats.
    filterTick = filterStats.tick,
    filterApplied = filterStats.applied,

    -- Pose availability.
    hasPhoneQuat = lastRawQuat ~= nil,
    hasPhonePos = rawPhonePos ~= nil,
    hasRef = hasNeutral,
    pendingRecenter = pendingRecenter,
    isFreeCamera = commands.isFreeCamera(),

    -- Live rates (per second).
    rotRate = rotRate,
    filterAppliedRate = appliedRate,
    filterTickRate = tickRate,

    deltaAngle = deltaAngleDeg(),   -- nil until first recenter + sample
    posDelta = posDelta,            -- camera-local; nil until position + recenter
  }
end

M.setEnabled = function(v)
  enabled = v and true or false
  log('I', 'phoneCamera', 'enabled = ' .. tostring(enabled))
end

-- Smoothing knob in seconds (UI slider 0.01..0.5). Scales BOTH responses:
-- response = base / max(0.02, seconds/0.06). Default 0.06 leaves them at base.
M.setSmoothing = function(seconds)
  smoothingSeconds = math.max(0.001, tonumber(seconds) or 0.06)
  log('I', 'phoneCamera', string.format('smoothing = %.3fs (rotResp=%.1f transResp=%.1f)',
    smoothingSeconds, rotResponse(), transResponse()))
end

M.setPort = function(port)
  listenPort = tonumber(port) or 4444
  openJsonSocket()
end

M.setOscPort = function(port)
  oscPort = tonumber(port) or 9000
  openOscSocket()
end

M.setPositionScale = function(scale)
  positionScale = tonumber(scale) or 1.0
  log('I', 'phoneCamera', 'position scale = ' .. positionScale)
end

M.setPositionEnabled = function(v)
  positionEnabled = v and true or false
  log('I', 'phoneCamera', 'position enabled = ' .. tostring(positionEnabled))
end

-- ---- Deprecated stubs -------------------------------------------------
-- The gravity/hold/mirror/calibration machinery is gone (the per-axis
-- mapping needs none of it). These stay so the existing UI buttons and any
-- saved console habits don't error.
local function deprecated(name)
  print('phoneCamera ' .. name .. ': deprecated - no longer needed with the per-axis mapping')
end
M.setHoldMode     = function() deprecated('setHoldMode') end
M.setMirror       = function() deprecated('setMirror') end
M.calibrate       = function() deprecated('calibrate') end
M.calibrateReset  = function() deprecated('calibrateReset') end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate

return M
