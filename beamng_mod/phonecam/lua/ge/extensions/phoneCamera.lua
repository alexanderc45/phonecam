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
--        pos  (x, y, z)    -> (x, -z, y)               [arkitPosToBeamNG]
-- Position axis signs are provisional pending in-game verification (a
-- real ARKit capture showed "lift up" as -Y) — see the sign consts below.
--
-- ---- Recentering --------------------------------------------
-- The phone's absolute heading is meaningless in-game, so on "recenter"
-- we capture the current phone pose as the reference:
--   refQuat = phoneQuat        refPos = phonePos
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

-- ARKit -> BeamNG position axis mapping. The base swap is (x,y,z)->(x,-z,y);
-- each output axis has its own sign here so signs can be flipped trivially
-- during in-game verification without touching the swap logic below.
local POS_SIGN_X =  1   -- BeamNG X  <-  ARKit x
local POS_SIGN_Y = -1   -- BeamNG Y  <-  ARKit z   (negated)
local POS_SIGN_Z =  1   -- BeamNG Z  <-  ARKit y

-- State -------------------------------------------------------
local udp = nil             -- JSON listen socket (:listenPort)
local udpOsc = nil          -- OSC  listen socket (:oscPort)
local enabled = true
local phoneQuat = nil       -- latest phone orientation (BeamNG frame)
local phonePos = nil        -- latest phone position    (BeamNG frame)
local refQuat = nil         -- phone orientation captured at recenter
local refPos = nil          -- phone position captured at recenter
local camBase = nil         -- camera orientation captured at recenter (free cam)
local currentQuat = nil     -- smoothed free-cam output orientation
local currentDelta = nil    -- smoothed head-look delta quat (filter path)
local currentPosDelta = nil -- smoothed position delta vec3  (filter path)
local pendingRecenter = false
local packetsSeen = 0
-- Per-kind datagram counters for extensions.phoneCamera.debug()
local stats = { json = 0, osc = 0, oscRot = 0, oscPos = 0, oscOther = 0, other = 0 }

-- Convert the phone's Y-up quaternion into BeamNG's Z-up frame.
-- (x, y, z, w) -> (x, -z, y, w). Reused by both the JSON and OSC paths.
local function phoneToBeamNG(q)
  return quat(q[1], -q[3], q[2], q[4])
end

-- Convert an ARKit (Y-up, meters) position offset into BeamNG's Z-up
-- frame. Base swap (x, y, z) -> (x, -z, y); signs are the adjustable
-- consts above (PROVISIONAL — verify in-game).
local function arkitPosToBeamNG(x, y, z)
  return vec3(POS_SIGN_X * x, POS_SIGN_Y * z, POS_SIGN_Z * y)
end

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
  ffiBuf = ffi.new('uint8_t[4]')
  ffiFloatPtr = ffi.cast('float*', ffiBuf)
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
    if tags ~= 'ffff' then return end
    local x = readFloatBE(data, argPos)
    local y = readFloatBE(data, argPos + 4)
    local z = readFloatBE(data, argPos + 8)
    local w = readFloatBE(data, argPos + 12)
    if not (x and y and z and w) then return end
    if isnaninf(x) or isnaninf(y) or isnaninf(z) or isnaninf(w) then return end
    local n2 = x*x + y*y + z*z + w*w
    -- reject junk; tolerate small drift then normalize (per spec: reject
    -- if |norm^2 - 1| > 0.1).
    if isnaninf(n2) or n2 < 1e-6 or math.abs(n2 - 1) > 0.1 then return end
    local inv = 1 / math.sqrt(n2)
    phoneQuat = phoneToBeamNG({ x*inv, y*inv, z*inv, w*inv })
    stats.oscRot = stats.oscRot + 1
    if stats.oscRot == 1 then print('phoneCamera: first OSC rotation received — phone is live') end
    onFirstSample()
  else -- isPos
    if tags ~= 'fff' then return end
    local x = readFloatBE(data, argPos)
    local y = readFloatBE(data, argPos + 4)
    local z = readFloatBE(data, argPos + 8)
    if not (x and y and z) then return end
    if isnaninf(x) or isnaninf(y) or isnaninf(z) then return end
    phonePos = arkitPosToBeamNG(x, y, z)
    if not refPos then refPos = phonePos end   -- auto-center first position sample
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

-- Smoothed camera-local head-look delta (refQuat^-1 * phoneQuat),
-- nlerp-smoothed framerate-independently. Returns nil when disabled or
-- no data. Self-guards against NaN so the filter never gets a bad quat.
M.getHeadLookDelta = function(dtReal)
  if not enabled or not refQuat or not phoneQuat then return nil end
  local target = refQuat:inversed() * phoneQuat
  local t = 1 - math.exp(-(dtReal or 0.016) / smoothingTau)
  currentDelta = currentDelta and nlerp(currentDelta, target, t) or target
  if isnaninf(currentDelta:squaredNorm()) then currentDelta = nil; return nil end
  return currentDelta
end

-- Smoothed camera-local position delta remap(phonePos - refPos)*scale,
-- exponentially smoothed with the same time constant as the quat.
-- Returns nil when disabled/position-off/no data. Self-guards NaN.
M.getPosDelta = function(dtReal)
  if not enabled or not positionEnabled or not refPos or not phonePos then return nil end
  -- Both are stored already in BeamNG axes, so the subtraction is the
  -- remapped local offset (the remap is a linear axis swap, so
  -- remap(a-b) == remap(a)-remap(b)).
  local target = (phonePos - refPos) * positionScale
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
end

local function onExtensionUnloaded()
  if udp then udp:close(); udp = nil end
  if udpOsc then udpOsc:close(); udpOsc = nil end
end

local function onUpdate(dtReal)
  drainSocket(udp)
  drainSocket(udpOsc)

  -- Process a pending recenter as soon as we have an orientation. This
  -- runs regardless of camera mode so the filter's reference is valid in
  -- orbit/hood/cab/chase, not just free cam.
  if pendingRecenter and phoneQuat then
    pendingRecenter = false
    refQuat = phoneQuat
    refPos = phonePos            -- may be nil (JSON path has no position); fine
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
  local target = camBase * (refQuat:inversed() * phoneQuat)

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
    phoneQuat and 'yes' or 'NO', phonePos and 'yes' or 'NO',
    refQuat and 'yes' or 'NO', refPos and 'yes' or 'NO', tostring(pendingRecenter)))
  print(string.format('  camera: isFreeCamera=%s', tostring(commands.isFreeCamera())))
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

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate

return M
