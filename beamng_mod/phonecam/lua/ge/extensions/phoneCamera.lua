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
-- ---- Coordinate systems -------------------------------------
-- The phone (three.js JSON path OR ARKit via LOTA) reports pose in a
-- right-handed, Y-UP world:  X = east, Y = UP, Z = south.
-- BeamNG's world is Z-UP:    X = east, Y = north, Z = UP.
-- Change of basis = rotate +90 deg about X, so Y -> Z and Z -> -Y:
--        quat (x, y, z, w) -> (x, -z, y, w)            [phoneToBeamNG]
--        pos: raw ARKit, mapped per-frame in getPosDelta (shares the
--        rotation path's axis correction; see that function's comment)
-- Position axis signs are provisional pending in-game verification (a
-- real ARKit capture showed "lift up" as -Y) — see the sign consts below.
--
-- ---- Recentering --------------------------------------------
-- The phone's absolute heading is meaningless in-game, so on "recenter"
-- we capture the current phone pose as the reference:
--   refQuat = phoneQuat        refRawQuat/refRawPos = raw ARKit pose
-- and only ever apply the RELATIVE pose since then. LOTA has no phone-side
-- recenter button; console recenter() covers it (and the first sample
-- auto-recenters so the view never snaps on connect).
-- ============================================================

local M = {}

local socket = require('socket.socket')   -- LuaSocket ships with BeamNG

-- isnaninf is an engine global; local fallback keeps this file safe to
-- syntax-check / reason about standalone.
local isnaninf = isnaninf or function(x) return x ~= x or x == math.huge or x == -math.huge end

-- Tunables ----------------------------------------------------
local listenHost = '127.0.0.1'   -- JSON relay runs on this PC
local listenPort = 4444
local oscHost    = '0.0.0.0'     -- LOTA streams from the phone over LAN
local oscPort    = 9000          -- LOTA default
local smoothingTau = 0.06        -- seconds; smoothing time constant
                                 -- (bigger = smoother but laggier)
local positionScale   = 1.0      -- meters -> world units multiplier
local positionEnabled = true     -- 6DOF translation on/off (filter path only)

-- Hold mode + mirror correction (rotation only; see handleOsc's isRot branch).
-- ARKit reports poses in a LANDSCAPE device frame, but users film holding the
-- phone PORTRAIT, so raw pitch/yaw/roll land on the wrong camera axes. Two
-- device-local corrections fix this without touching the world change-of-basis:
--   * mirrorRotation: quaternion conjugate (negate x,y,z) — undoes an improper
--     / mirrored mapping (roll appears inverted).
--   * holdMode 0..3: relabels axes by rotating holdMode*90deg about the phone's
--     local z (view) axis, i.e. how the phone is physically held.
--       0 = landscape, 1 = portrait (default; how the user films),
--       2 = upside-down, 3 = landscape-rotated.
-- Both are applied per-packet; the sin/cos for the hold rotation is precomputed
-- on change (recomputeHold) rather than per packet.
local holdMode = 1               -- default 1 = portrait
local mirrorRotation = false
local holdS, holdC = 0, 1        -- sin/cos(holdMode*90deg / 2)
local function recomputeHold()
  -- Signed angle so mode 3 is -90deg (not +270); representation only — +270
  -- and -90 are the same rotation, but this matches the spec's table exactly.
  local deg = holdMode * 90
  if deg > 180 then deg = deg - 360 end     -- 0, +90, +180, -90
  local theta = deg * math.pi / 180
  holdS = math.sin(theta / 2)
  holdC = math.cos(theta / 2)
end
recomputeHold()

-- Position is handled in RAW ARKit coordinates and mapped through the SAME
-- correction chain as rotation (see getPosDelta): world displacement ->
-- neutral-device frame (rotate by refRawQuat^-1) -> axis correction
-- (rotate by holdQuat^-1) -> Y-up->Z-up component swap. The result is a
-- CAMERA-LOCAL offset (right/forward/up), which is exactly what the
-- phonelook filter applies (data.res.pos + baseRot * pd). This makes
-- physical movement relative to the recentered facing and automatically
-- consistent with whatever axis calibration is active.

-- State -------------------------------------------------------
local udp = nil             -- JSON listen socket (:listenPort)
local udpOsc = nil          -- OSC  listen socket (:oscPort)
local enabled = true
local phoneQuat = nil       -- latest phone orientation (BeamNG frame)
local rawPhonePos = nil     -- latest phone position {x,y,z}, RAW ARKit frame
local refQuat = nil         -- phone orientation captured at recenter
local refRawQuat = nil      -- RAW ARKit quat captured at recenter (position frame)
local refRawPos = nil       -- RAW ARKit position captured at recenter
local camBase = nil         -- camera orientation captured at recenter (free cam)
local currentQuat = nil     -- smoothed free-cam output orientation
local currentDelta = nil    -- smoothed head-look delta quat (filter path)
local currentPosDelta = nil -- smoothed position delta vec3  (filter path)
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

-- ---- Axis auto-calibration --------------------------------------------
-- Hold-mode presets proved insufficient in the field (the needed correction
-- was not a screen-plane rotation). Instead, MEASURE the user's real axes:
--   step 1: capture neutral pose        step 2: capture "pitch up ~45deg"
--   step 3: re-capture neutral          step 4: capture "turn left ~45deg"
-- The pitch gesture's rotation axis (device frame) is the user's pitch axis
-- p; the yaw gesture gives u; w = p x u completes a right-handed frame. A
-- post-multiplied constant quat P conjugates every delta by rot(P)^T, and
-- the required target axes reduce to the standard basis under our
-- Y-up->Z-up swap (X->camPitch, Y->camYaw, Z->-camRoll pre-swap), so P is
-- simply the quaternion of the matrix whose COLUMNS are p, u, w.
local lastRawQuat = nil       -- latest raw ARKit quat {x,y,z,w}, pre-correction
-- Default correction: SOLVED from Alex's two in-game reports by brute-forcing
-- the unique device frame consistent with both (see scratchpad
-- solve_mapping.lua): user axes in LOTA's device frame are p=(0,0,-1),
-- u=(1,0,0), w=(0,-1,0), giving P = quatFromColumns = (-0.5,-0.5,0.5,-0.5).
-- Verified to map pitch->camX, yaw->camZ, roll->camY exactly. The
-- calibration wizard overwrites this for other grips/devices.
local DEFAULT_HOLD_QUAT = { -0.5, -0.5, 0.5, -0.5 }
local holdQuat = DEFAULT_HOLD_QUAT  -- correction {x,y,z,w}
local calibStep = 0           -- 0 idle; 1..3 = wizard progress
local calibA, calibP = nil, nil  -- captured neutral quat / pitch axis

-- ---- Gravity-derived grip frame (the default mode) --------------------
-- The correction is recomputed AT EVERY RECENTER from what is actually
-- measurable in that instant: ARKit's world +Y is gravity-up, so the
-- user's up-axis in device coordinates is exact (refRaw^-1 * worldUp).
-- The device view axis is the one remaining constant (VIEW_AXIS_DEV,
-- field-solved: LOTA's device +y points at the scene); it is
-- horizontalized against the measured up, right = view x up, and the
-- wizard formula (columns right, up, right x up) yields the correction.
-- Result: recenter in ANY grip/tilt and pitch/yaw/roll align to it —
-- fixes the "auto-recenter fired while the phone lay on the desk" frame
-- scramble that a fixed correction cannot handle.
-- gripAuto=false (wizard or manual preset) locks holdQuat instead.
-- ARKit camera convention: the lens looks along device -Z. (An earlier
-- value of (0,1,0) was inherited from a brute-force fit to sessions whose
-- reference frame was corrupt — it put "forward" on the user's right and
-- swapped pitch/roll while gravity kept yaw correct. Field symptom matched
-- exactly; -Z is also the documented ARKit camera axis.)
local VIEW_AXIS_DEV = { 0, 0, -1 }
local gripAuto = true
local lastRotClock = nil      -- frameClock at last rotation packet; a >2s
                              -- gap in the stream triggers auto-recenter
                              -- (console-free re-zero: toggle LOTA's stream)

-- ---- Recenter stability gate ------------------------------------------
-- Root cause of session-to-session axis inconsistency: recenter used to
-- fire on the FIRST packet — i.e. whatever pose the phone was in while the
-- user tapped LOTA's shutter (usually pointed at the floor/desk). Now a
-- pending recenter only executes once the phone is (a) roughly level (view
-- axis within ~45deg of horizontal) and (b) held steady (< ~20deg/s) for
-- STABLE_HOLD_S. Tap the shutter however you like; the frame locks when
-- you actually raise and aim the phone.
local STABLE_HOLD_S = 0.7
local prevRawQuat = nil       -- previous rotation sample (rate estimation)
local lastUnstableClock = nil -- frameClock when the pose was last unstable
local recenterDeferLogged = false

-- Real-time seconds accumulated from onUpdate's dtReal. Used only as the
-- clock for the UI app's live-rate math, so we never touch a wall-clock
-- API (dtReal is the engine's real frame delta and always available here).
local frameClock = 0
-- Previous counter snapshot for M.getUiStatus() rate computation. Holds the
-- last sample time, the counters at that time, and the last rates we
-- reported (reused when two polls land in the same frame so rates don't
-- flicker to zero).
local uiRatePrev = nil

-- Rotate vector v = {x,y,z} by unit quaternion q = {x,y,z,w}: v' = q v q^-1.
-- Plain-table math (no engine types) so it composes with the raw ARKit data.
-- MUST be defined before correctRaw/computeGripCorrection/rawPosDeltaCamLocal,
-- which capture it as an upvalue (a later declaration would silently resolve
-- to a nil global inside them -> fatal on the first recenter).
local function qRotateVec(q, vx, vy, vz)
  local qx, qy, qz, qw = q[1], q[2], q[3], q[4]
  -- t = 2 * cross(q.xyz, v)
  local tx = 2 * (qy*vz - qz*vy)
  local ty = 2 * (qz*vx - qx*vz)
  local tz = 2 * (qx*vy - qy*vx)
  -- v' = v + w*t + cross(q.xyz, t)
  return vx + qw*tx + (qy*tz - qz*ty),
         vy + qw*ty + (qz*tx - qx*tz),
         vz + qw*tz + (qx*ty - qy*tx)
end

-- Convert the phone's Y-up quaternion into BeamNG's Z-up frame.
-- (x, y, z, w) -> (x, -z, y, w). Reused by both the JSON and OSC paths.
local function phoneToBeamNG(q)
  return quat(q[1], -q[3], q[2], q[4])
end

-- Apply the full device-side correction chain to a raw ARKit quat {x,y,z,w}:
-- mirror (z-plane reflection), then the axis correction (calibrated/derived
-- holdQuat, or the holdMode preset), then the Y-up->Z-up swap. Single source
-- of truth used by the packet path AND by recenter's re-derivation.
local function correctRaw(q4)
  local qx, qy, qz, qw = q4[1], q4[2], q4[3], q4[4]
  if mirrorRotation then qx, qy = -qx, -qy end
  local bx, by, bz, bw
  if holdQuat then
    bx, by, bz, bw = holdQuat[1], holdQuat[2], holdQuat[3], holdQuat[4]
  else
    bx, by, bz, bw = 0, 0, holdS, holdC
  end
  local hx = qw*bx + qx*bw + qy*bz - qz*by
  local hy = qw*by + qy*bw + qz*bx - qx*bz
  local hz = qw*bz + qz*bw + qx*by - qy*bx
  local hw = qw*bw - qx*bx - qy*by - qz*bz
  return phoneToBeamNG({ hx, hy, hz, hw })
end

-- Matrix (columns p,u,w) -> quat, with snap-to-exact-axes when unambiguous.
-- Shared by the calibration wizard and the gravity grip derivation.
local function quatFromColumns(p, u, w)
  local m = { { p[1], u[1], w[1] }, { p[2], u[2], w[2] }, { p[3], u[3], w[3] } }
  local snapped, ok = { {0,0,0}, {0,0,0}, {0,0,0} }, true
  for c = 1, 3 do
    local col = { m[1][c], m[2][c], m[3][c] }
    local bi, bv = 1, math.abs(col[1])
    for i = 2, 3 do if math.abs(col[i]) > bv then bi, bv = i, math.abs(col[i]) end end
    if bv < 0.8 then ok = false break end
    snapped[bi][c] = col[bi] > 0 and 1 or -1
  end
  if ok then
    for r = 1, 3 do
      local nz = math.abs(snapped[r][1]) + math.abs(snapped[r][2]) + math.abs(snapped[r][3])
      if nz ~= 1 then ok = false break end
    end
    if ok then m = snapped end
  end
  local m11, m12, m13 = m[1][1], m[1][2], m[1][3]
  local m21, m22, m23 = m[2][1], m[2][2], m[2][3]
  local m31, m32, m33 = m[3][1], m[3][2], m[3][3]
  local tr = m11 + m22 + m33
  local qx, qy, qz, qw
  if tr > 0 then
    local S = math.sqrt(tr + 1) * 2
    qw = S / 4; qx = (m32 - m23) / S; qy = (m13 - m31) / S; qz = (m21 - m12) / S
  elseif m11 > m22 and m11 > m33 then
    local S = math.sqrt(1 + m11 - m22 - m33) * 2
    qx = S / 4; qw = (m32 - m23) / S; qy = (m12 + m21) / S; qz = (m13 + m31) / S
  elseif m22 > m33 then
    local S = math.sqrt(1 + m22 - m11 - m33) * 2
    qy = S / 4; qw = (m13 - m31) / S; qx = (m12 + m21) / S; qz = (m23 + m32) / S
  else
    local S = math.sqrt(1 + m33 - m11 - m22) * 2
    qz = S / 4; qw = (m21 - m12) / S; qx = (m13 + m31) / S; qy = (m23 + m32) / S
  end
  local n = math.sqrt(qx*qx + qy*qy + qz*qz + qw*qw)
  return { qx/n, qy/n, qz/n, qw/n }, ok
end

-- Derive the grip correction from gravity at a given raw attitude:
--   up (device coords)  = refRaw^-1 * worldUp   (exact, gravity-measured)
--   view                = VIEW_AXIS_DEV horizontalized against up
--   right               = view x up
-- Returns nil when the view axis is within ~18deg of vertical (phone
-- pointing straight up/down — no stable heading to build a frame from).
local function computeGripCorrection(refRaw)
  local iq = { -refRaw[1], -refRaw[2], -refRaw[3], refRaw[4] }
  local ux, uy, uz = qRotateVec(iq, 0, 1, 0)
  local un = math.sqrt(ux*ux + uy*uy + uz*uz)
  if un < 1e-6 then return nil end
  ux, uy, uz = ux/un, uy/un, uz/un
  local fx, fy, fz = VIEW_AXIS_DEV[1], VIEW_AXIS_DEV[2], VIEW_AXIS_DEV[3]
  local d = fx*ux + fy*uy + fz*uz
  fx, fy, fz = fx - d*ux, fy - d*uy, fz - d*uz
  local fn = math.sqrt(fx*fx + fy*fy + fz*fz)
  if fn < 0.3 then return nil end        -- view too close to vertical
  fx, fy, fz = fx/fn, fy/fn, fz/fn
  -- right = view x up; wizard columns are (p=right, u=up, w=p x u)
  local rx = fy*uz - fz*uy
  local ry = fz*ux - fx*uz
  local rz = fx*uy - fy*ux
  local wx = ry*uz - rz*uy
  local wy = rz*ux - rx*uz
  local wz = rx*uy - ry*ux
  return quatFromColumns({ rx, ry, rz }, { ux, uy, uz }, { wx, wy, wz })
end

-- (qRotateVec is defined above phoneToBeamNG — it must precede every
-- function that captures it as an upvalue.)

-- Normalized linear interpolation between quaternions. Good enough for
-- frame-to-frame smoothing (angles are tiny); the sign flip picks the
-- shorter arc, since q and -q are the same rotation.
local function nlerp(a, b, t)
  local dot = a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w
  local s = dot < 0 and -1 or 1
  return quat(
    a.x + (s*b.x - a.x) * t,
    a.y + (s*b.y - a.y) * t,
    a.z + (s*b.z - a.z) * t,
    a.w + (s*b.w - a.w) * t
  ):normalized()
end

-- ---- Big-endian float32 decode (no string.unpack on LuaJIT) ----------
-- LuaJIT ffi fast path: write the 4 bytes reversed into a byte buffer
-- aliased as a float. Assumes a little-endian host (x86-64 / Apple
-- silicon — every platform BeamNG runs on), so the network (big-endian)
-- MSB..LSB bytes are stored LSB-first.
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
-- no-op — indexing then returns the raw byte instead of the aliased float
-- (observed in the field: every float decoded as its own last byte). Decode
-- the known constant 1.0f (big-endian 3f 80 00 00); if the fast path lies,
-- disable it and rely on the pure-Lua decoder below.
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
-- Returns nil if fewer than 4 bytes are available.
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
-- Called whenever a fresh pose sample lands; auto-recenter on the very
-- first one so the camera doesn't jump when the phone connects.
local function onFirstSample()
  packetsSeen = packetsSeen + 1
  if packetsSeen == 1 then pendingRecenter = true end
end

-- ---- JSON path (legacy web client via relay) — kept verbatim ---------
local function handleJson(data)
  local msg = jsonDecode(data)
  if not msg then return end
  if msg.t == 'o' and type(msg.q) == 'table' and #msg.q == 4 then
    phoneQuat = phoneToBeamNG(msg.q)
    onFirstSample()
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
  -- We only consume rotation/position; euler/mode/fps and anything else
  -- are ignored (cheap early-out before decoding args).
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
    -- reject junk; tolerate small drift then normalize (per spec: reject
    -- if |norm^2 - 1| > 0.1).
    if isnaninf(n2) or n2 < 1e-6 or math.abs(n2 - 1) > 0.1 then
      rotFails.norm = rotFails.norm + 1
      lastRotRaw = data:sub(1, 64)
      lastRotInfo = string.format('norm2=%.6f from %g %g %g %g', n2, x, y, z, w)
      return
    end
    local inv = 1 / math.sqrt(n2)
    -- NOTE: do NOT conjugate here — that was tried and it scrambles the
    -- gravity frame derivation (which reads this same quat). The uniform
    -- direction flip is corrected at the DELTA level in getHeadLookDelta,
    -- after all frame math (see comment there).
    lastRawQuat = { x*inv, y*inv, z*inv, w*inv }

    -- Console-free re-zero: a gap in the stream (LOTA toggled off/on, app
    -- backgrounded) means the user repositioned — re-derive the frame.
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
      prevRawQuat = lastRawQuat
    end
    lastRotClock = frameClock

    -- Full correction chain (mirror -> holdQuat/preset -> Y-up->Z-up swap).
    phoneQuat = correctRaw(lastRawQuat)
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
    rawPhonePos = { x, y, z }                  -- raw ARKit meters; mapped in getPosDelta
    if not refRawPos then refRawPos = rawPhonePos end  -- auto-center first sample
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

-- Smoothed camera-local head-look delta (refQuat^-1 * phoneQuat),
-- nlerp-smoothed framerate-independently. Returns nil when disabled or
-- no data. Self-guards against NaN so the filter never gets a bad quat.
M.getHeadLookDelta = function(dtReal)
  if not enabled or not refQuat or not phoneQuat then return nil end
  -- INVERTED delta (phone^-1 * ref instead of ref^-1 * phone): field
  -- testing on the gravity-frame build showed every axis tracking
  -- correctly but uniformly opposite, so the camera applies the exact
  -- inverse of the phone's relative rotation. Flipping the delta AFTER
  -- all frame math keeps the gravity derivation untouched (conjugating
  -- the raw quat instead breaks it — tried).
  local target = phoneQuat:inversed() * refQuat
  local t = 1 - math.exp(-(dtReal or 0.016) / smoothingTau)
  currentDelta = currentDelta and nlerp(currentDelta, target, t) or target
  if isnaninf(currentDelta:squaredNorm()) then currentDelta = nil; return nil end
  return currentDelta
end

-- Smoothed camera-local position delta,
-- exponentially smoothed with the same time constant as the quat.
-- Returns nil when disabled/position-off/no data. Self-guards NaN.
-- Camera-local position delta, sharing the rotation path's axis correction:
--   ARKit world displacement (phone - recenter)
--     -> neutral device frame   (rotate by refRawQuat^-1)
--     -> corrected user frame   (rotate by holdQuat^-1; mirror reflects x,y)
--     -> BeamNG camera-local    (component swap (x,y,z) -> (x,-z,y))
-- The result means: user walks right -> camera moves right relative to the
-- recentered shot, regardless of where ARKit's arbitrary world heading is.
-- Unscaled, unsmoothed camera-local displacement since recenter (vec3), or
-- nil. Shared by getPosDelta (which scales + smooths it) and the debug/UI
-- readouts, so what you see is what the camera gets.
local function rawPosDeltaCamLocal()
  if not refRawPos or not rawPhonePos or not refRawQuat then return nil end
  local wx = rawPhonePos[1] - refRawPos[1]
  local wy = rawPhonePos[2] - refRawPos[2]
  local wz = rawPhonePos[3] - refRawPos[3]
  -- world -> neutral device frame (conjugate rotation)
  local iq = { -refRawQuat[1], -refRawQuat[2], -refRawQuat[3], refRawQuat[4] }
  local dx, dy, dz = qRotateVec(iq, wx, wy, wz)
  if mirrorRotation then dx, dy = -dx, -dy end
  -- device -> corrected user frame (falls back to the holdMode preset quat
  -- when the calibrated/default holdQuat was cleared via setHoldMode)
  local hq = holdQuat or { 0, 0, holdS, holdC }
  local hp = { -hq[1], -hq[2], -hq[3], hq[4] }
  local ux, uy, uz = qRotateVec(hp, dx, dy, dz)
  -- Y-up -> Z-up swap into camera-local right/forward/up
  return vec3(ux, -uz, uy)
end

M.getPosDelta = function(dtReal)
  if not enabled or not positionEnabled then return nil end
  local raw = rawPosDeltaCamLocal()
  if not raw then return nil end
  local target = raw * positionScale
  local t = 1 - math.exp(-(dtReal or 0.016) / smoothingTau)
  if currentPosDelta then
    currentPosDelta = currentPosDelta + (target - currentPosDelta) * t
  else
    currentPosDelta = target
  end
  if isnaninf(currentPosDelta:squaredLength()) then currentPosDelta = nil; return nil end
  return currentPosDelta
end

-- ---- Per-frame ------------------------------------------------------
local function onExtensionLoaded()
  openJsonSocket()
  openOscSocket()
  log('I', 'phoneCamera', 'loaded. Head-look composes onto ANY camera mode via the phonelook filter;')
  log('I', 'phoneCamera', 'the free camera (Shift+C) still uses the legacy writer. Stream from your phone.')
  log('I', 'phoneCamera', 'console: extensions.phoneCamera.recenter() / setEnabled(bool) / setSmoothing(s) /')
  log('I', 'phoneCamera', '         setPort(n) / setOscPort(n) / setPositionScale(n) / setPositionEnabled(bool)')
  log('I', 'phoneCamera', '         setHoldMode(0..3) / setMirror(bool)  (fix portrait/landscape axis scramble)')
end

local function onExtensionUnloaded()
  if udp then udp:close(); udp = nil end
  if udpOsc then udpOsc:close(); udpOsc = nil end
end

local function onUpdate(dtReal)
  frameClock = frameClock + (dtReal or 0)   -- real-time base for UI rates
  drainSocket(udp)
  drainSocket(udpOsc)

  -- Process a pending recenter as soon as we have an orientation. This
  -- runs regardless of camera mode so the filter's reference is valid in
  -- orbit/hood/cab/chase, not just free cam.
  -- A pending recenter waits for the stability gate: phone roughly level
  -- and steady for STABLE_HOLD_S (see the gate's comment). JSON path has no
  -- stability data (lastUnstableClock stays nil until OSC flows) — treat it
  -- as immediately stable to preserve legacy web-client behavior.
  local recenterReady = (lastUnstableClock == nil)
      or ((frameClock - lastUnstableClock) >= STABLE_HOLD_S)
  if pendingRecenter and phoneQuat and not recenterReady and not recenterDeferLogged then
    recenterDeferLogged = true
    print('phoneCamera: recenter armed - hold the phone level and steady to lock the frame')
  end
  if pendingRecenter and phoneQuat and recenterReady then
    pendingRecenter = false
    recenterDeferLogged = false
    -- Gravity mode: re-derive the axis correction from THIS grip's attitude
    -- before capturing references, so pitch/roll align to however the phone
    -- is actually held right now. Falls back to the previous correction when
    -- the phone points near-vertically (no stable heading).
    if gripAuto and lastRawQuat then
      local g = computeGripCorrection(lastRawQuat)
      if g then holdQuat = g end
    end
    -- Recompute the converted pose with the (possibly new) correction so the
    -- reference and subsequent packets share one frame.
    if lastRawQuat then
      phoneQuat = correctRaw(lastRawQuat)
    end
    refQuat = phoneQuat
    refRawQuat = lastRawQuat     -- raw ARKit reference for the position frame
    refRawPos = rawPhonePos      -- may be nil (JSON path has no position); fine
    currentDelta = nil
    currentPosDelta = nil
    if commands.isFreeCamera() then
      -- Capture the free-cam base in the SAME frame as refQuat so the
      -- view never snaps (matches the original behavior).
      camBase = getCameraQuat()
      currentQuat = camBase
    else
      camBase = nil              -- capture on entry to free cam instead
      currentQuat = nil
    end
    log('I', 'phoneCamera', 'recentered: current phone pose is now the reference')
  end

  if not enabled or not phoneQuat then return end

  -- Legacy free-cam writer. Only drives the free camera; every other mode
  -- is handled by the phonelook filter (which early-returns on free cam,
  -- so there is no double-apply). Kept rotation-only and unchanged.
  if not commands.isFreeCamera() then return end
  if not refQuat then return end
  if not camBase then                      -- entered free cam after a recenter elsewhere
    camBase = getCameraQuat()
    currentQuat = camBase
  end

  -- Relative rotation since recenter, applied to the camera base.
  -- Inverted delta, matching getHeadLookDelta (see comment there).
  local target = camBase * (phoneQuat:inversed() * refQuat)

  -- Framerate-independent exponential smoothing: t = 1 - e^(-dt/tau).
  local t = 1 - math.exp(-(dtReal or 0.016) / smoothingTau)
  currentQuat = currentQuat and nlerp(currentQuat, target, t) or target

  -- Keep the camera's position, replace only its rotation.
  local pos = getCameraPosition()
  setCameraPosRot(pos.x, pos.y, pos.z,
                  currentQuat.x, currentQuat.y, currentQuat.z, currentQuat.w)
end

-- Public API (console: extensions.phoneCamera.<fn>) ------------
M.recenter = function() pendingRecenter = true end

-- One-shot status dump via print() (always visible in the console
-- regardless of log-level filters). The first place to look when
-- "nothing happens".
M.debug = function()
  print('phoneCamera status:')
  print(string.format('  enabled=%s positionEnabled=%s scale=%.2f tau=%.3fs',
    tostring(enabled), tostring(positionEnabled), positionScale, smoothingTau))
  print(string.format('  sockets: json=%s:%d (%s)  osc=%s:%d (%s)',
    listenHost, listenPort, udp and 'open' or 'CLOSED',
    oscHost, oscPort, udpOsc and 'open' or 'CLOSED'))
  print(string.format('  datagrams: json=%d osc=%d (rot=%d pos=%d other=%d) unknown=%d',
    stats.json, stats.osc, stats.oscRot, stats.oscPos, stats.oscOther, stats.other))
  print(string.format('  pose: phoneQuat=%s phonePos=%s refQuat=%s refPos=%s pendingRecenter=%s',
    phoneQuat and 'yes' or 'NO', rawPhonePos and 'yes' or 'NO',
    refQuat and 'yes' or 'NO', refRawPos and 'yes' or 'NO', tostring(pendingRecenter)))
  print(string.format('  camera: isFreeCamera=%s', tostring(commands.isFreeCamera())))
  print(string.format('  rotFails: tags=%d short=%d nonfinite=%d norm=%d',
    rotFails.tags, rotFails.short, rotFails.nonfinite, rotFails.norm))
  print(string.format('  filter: tick=%d applied=%d  phonelookFile=%s',
    filterStats.tick, filterStats.applied,
    tostring(FS:fileExists('/lua/ge/extensions/core/cameraModes/phonelook.lua'))))
  if phoneQuat then
    print(string.format('  phoneQuat: %.4f %.4f %.4f %.4f', phoneQuat.x, phoneQuat.y, phoneQuat.z, phoneQuat.w))
  end
  if refQuat and phoneQuat then
    local d = refQuat:inversed() * phoneQuat
    local ang = 2 * math.acos(math.min(1, math.abs(d.w))) * 180 / math.pi
    print(string.format('  delta since recenter: %.4f %.4f %.4f %.4f  (angle %.1f deg)', d.x, d.y, d.z, d.w, ang))
  end
  local pd = rawPosDeltaCamLocal()
  if pd then
    print(string.format('  posDelta since recenter (cam-local): %.3f %.3f %.3f m', pd.x, pd.y, pd.z))
  end
  if lastRotInfo then print('  lastRotFail: ' .. lastRotInfo) end
  if lastRotRaw then
    local hex = {}
    for i = 1, #lastRotRaw do hex[i] = string.format('%02x', lastRotRaw:byte(i)) end
    print('  lastRotRaw: ' .. table.concat(hex))
  end
end

-- Single flat snapshot for the in-game UI app (ui/modules/apps/phoneCamera).
-- Mirrors debug() but returns ONE table (encodeJson'd by the bngApi bridge
-- into a JS object) and adds live per-second rates. Called ~4 Hz by the app.
-- Everything here is nil-safe so the app can poll before/while the phone is
-- connected; nil fields simply drop out of the JSON.
M.getUiStatus = function()
  local now = frameClock

  -- Live rates: delta(counter) / delta(time) since the previous poll. Every
  -- successful orientation datagram bumps either stats.json (web client; a
  -- json datagram is an orientation sample or the rare recenter) or
  -- stats.oscRot (LOTA), so their sum is the rotation-sample counter.
  local rotTotal = stats.json + stats.oscRot
  local rotRate, appliedRate, tickRate = 0, 0, 0
  if uiRatePrev then
    local dt = now - uiRatePrev.t
    if dt > 1e-3 then
      rotRate     = (rotTotal - uiRatePrev.rot) / dt
      appliedRate = (filterStats.applied - uiRatePrev.applied) / dt
      tickRate    = (filterStats.tick - uiRatePrev.tick) / dt
    else
      -- Two polls inside one frame: reuse last rates instead of dividing by ~0.
      rotRate     = uiRatePrev.rotRate or 0
      appliedRate = uiRatePrev.appliedRate or 0
      tickRate    = uiRatePrev.tickRate or 0
    end
  end
  uiRatePrev = {
    t = now, rot = rotTotal, applied = filterStats.applied, tick = filterStats.tick,
    rotRate = rotRate, appliedRate = appliedRate, tickRate = tickRate,
  }

  -- Delta since recenter (angle in degrees), matching debug()'s math.
  local deltaAngle = nil
  if refQuat and phoneQuat then
    local d = refQuat:inversed() * phoneQuat
    deltaAngle = 2 * math.acos(math.min(1, math.abs(d.w))) * 180 / math.pi
  end

  -- Position delta xyz since recenter (camera-local meters, pre-scale).
  local posDelta = nil
  local pd = rawPosDeltaCamLocal()
  if pd then
    posDelta = { x = pd.x, y = pd.y, z = pd.z }
  end

  return {
    enabled = enabled,
    positionEnabled = positionEnabled,
    positionScale = positionScale,
    smoothingTau = smoothingTau,
    holdMode = holdMode,
    mirrorRotation = mirrorRotation,
    calibStep = calibStep,
    calibrated = holdQuat ~= nil,
    gripAuto = gripAuto,

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
    hasPhoneQuat = phoneQuat ~= nil,
    hasPhonePos = rawPhonePos ~= nil,
    hasRef = refQuat ~= nil,
    pendingRecenter = pendingRecenter,
    isFreeCamera = commands.isFreeCamera(),

    -- Live rates (per second).
    rotRate = rotRate,
    filterAppliedRate = appliedRate,
    filterTickRate = tickRate,

    deltaAngle = deltaAngle,   -- nil until first recenter + sample
    posDelta = posDelta,       -- camera-local; nil until position + recenter exist
  }
end

M.setEnabled = function(v)
  enabled = v and true or false
  log('I', 'phoneCamera', 'enabled = ' .. tostring(enabled))
end

M.setSmoothing = function(seconds)
  smoothingTau = math.max(0.001, tonumber(seconds) or 0.06)
  log('I', 'phoneCamera', 'smoothing tau = ' .. smoothingTau .. 's')
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

-- Device-local hold mode 0..3 (0/90/180/270 deg about the phone's view axis).
-- Clamp+round to a valid index. A mapping change invalidates the recenter
-- reference, so force a recenter.
M.setHoldMode = function(n)
  n = math.floor((tonumber(n) or 0) + 0.5)
  if n < 0 then n = 0 elseif n > 3 then n = 3 end
  holdMode = n
  holdQuat = nil               -- manual preset overrides any calibration
  gripAuto = false             -- and disables gravity re-derivation
  recomputeHold()
  pendingRecenter = true
  log('I', 'phoneCamera', 'hold mode = ' .. holdMode .. ' (calibration cleared)')
end

-- Mirror (device z-plane reflection) toggle. Also invalidates the
-- reference, so force a recenter.
M.setMirror = function(v)
  mirrorRotation = v and true or false
  pendingRecenter = true
  log('I', 'phoneCamera', 'mirror rotation = ' .. tostring(mirrorRotation))
end

-- ---- Axis auto-calibration wizard ------------------------------------
-- Each call advances one step (UI button or console). Gestures are held
-- while pressing, all relative to the re-captured neutral pose.
local function calibDelta(a, b)
  -- device-frame rotation from pose a to pose b: a^-1 (x) b, unit quats
  local ax, ay, az, aw = -a[1], -a[2], -a[3], a[4]
  local bx, by, bz, bw = b[1], b[2], b[3], b[4]
  return aw*bx + ax*bw + ay*bz - az*by,
         aw*by + ay*bw + az*bx - ax*bz,
         aw*bz + az*bw + ax*by - ay*bx,
         aw*bw - ax*bx - ay*by - az*bz
end

-- (quatFromColumns is defined near the top of the file, shared with the
-- gravity grip derivation.)

M.calibrate = function()
  if not lastRawQuat then
    print('phoneCamera CALIBRATE: no phone data yet - start streaming first')
    return
  end
  local q = { lastRawQuat[1], lastRawQuat[2], lastRawQuat[3], lastRawQuat[4] }
  if calibStep == 0 then
    calibA = q
    calibStep = 1
    print('phoneCamera CALIBRATE 1/4: neutral captured. Now PITCH the phone UP ~45 deg, hold it there, press again.')
  elseif calibStep == 1 then
    local dx, dy, dz = calibDelta(calibA, q)
    local n = math.sqrt(dx*dx + dy*dy + dz*dz)
    if n < 0.17 then  -- sin(20deg/2)-ish: demand a clear gesture
      print('phoneCamera CALIBRATE: pitch gesture too small - pitch up further and press again.')
      return
    end
    calibP = { dx/n, dy/n, dz/n }
    calibStep = 2
    print('phoneCamera CALIBRATE 2/4: pitch axis captured. Return to NEUTRAL, hold, press again.')
  elseif calibStep == 2 then
    calibA = q
    calibStep = 3
    print('phoneCamera CALIBRATE 3/4: neutral re-captured. Now TURN (yaw) the phone LEFT ~45 deg, hold, press again.')
  else
    local dx, dy, dz = calibDelta(calibA, q)
    local n = math.sqrt(dx*dx + dy*dy + dz*dz)
    if n < 0.17 then
      print('phoneCamera CALIBRATE: yaw gesture too small - turn further left and press again.')
      return
    end
    local p = calibP
    local ux, uy, uz = dx/n, dy/n, dz/n
    -- orthonormalize the yaw axis against the pitch axis
    local dot = ux*p[1] + uy*p[2] + uz*p[3]
    ux, uy, uz = ux - dot*p[1], uy - dot*p[2], uz - dot*p[3]
    local un = math.sqrt(ux*ux + uy*uy + uz*uz)
    if un < 0.3 then
      print('phoneCamera CALIBRATE: yaw gesture too close to the pitch axis - redo the left turn, press again.')
      return
    end
    ux, uy, uz = ux/un, uy/un, uz/un
    local wx = p[2]*uz - p[3]*uy
    local wy = p[3]*ux - p[1]*uz
    local wz = p[1]*uy - p[2]*ux
    local hq, snapped = quatFromColumns(p, { ux, uy, uz }, { wx, wy, wz })
    holdQuat = hq
    gripAuto = false           -- wizard result is authoritative; no re-derivation
    mirrorRotation = false     -- calibration supersedes manual tweaks
    calibStep = 0
    calibA, calibP = nil, nil
    pendingRecenter = true
    print(string.format(
      'phoneCamera CALIBRATE done%s: correction quat (%.3f, %.3f, %.3f, %.3f). Recentered - aim and film.',
      snapped and ' (snapped to exact axes)' or ' (unsnapped, using measured axes)',
      hq[1], hq[2], hq[3], hq[4]))
  end
end

M.calibrateReset = function()
  calibStep = 0
  calibA, calibP = nil, nil
  holdQuat = DEFAULT_HOLD_QUAT   -- placeholder until the next recenter derives
  gripAuto = true                -- gravity mode back on
  pendingRecenter = true
  print('phoneCamera CALIBRATE: cleared (back to the default mapping)')
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate

return M
