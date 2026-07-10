-- ============================================================
-- BeamNG Phone Camera — GE Lua extension
--
-- Listens on a local UDP port (via BeamNG's bundled LuaSocket)
-- for orientation quaternions streamed from a phone, and applies
-- them to the free camera every frame.
--
-- ---- Coordinate systems -------------------------------------
-- The phone sends a quaternion built in a three.js-style world
-- frame:            X = east, Y = UP,   Z = south
-- BeamNG's world:   X = east, Y = north, Z = UP
--
-- Converting between them is a fixed change of basis: rotate the
-- source frame +90 degrees about X, so that  Y -> Z  and  Z -> -Y.
-- For a rotation quaternion this conjugation reduces to a simple
-- component swap (the axis part of a quaternion transforms like a
-- vector):
--        (x, y, z, w)_phone  ->  (x, -z, y, w)_beamng
--
-- ---- Recentering --------------------------------------------
-- We never apply the phone's absolute orientation (its compass
-- heading is meaningless in-game). Instead, on "recenter" we save
--   refQuat  = phone orientation at that instant
--   camBase  = in-game camera orientation at that instant
-- and each frame apply only the RELATIVE rotation since then:
--   target = camBase * (refQuat^-1 * phoneQuat)
-- q^-1 * p is the rotation "from q to p" expressed in the phone's
-- local frame; because both frames use camera conventions
-- (X right, Y forward, Z up after conversion) the same local
-- rotation is valid in the camera's local frame, so it is applied
-- by right-multiplying camBase.
-- ============================================================

local M = {}

local socket = require('socket.socket')   -- LuaSocket ships with BeamNG

-- Tunables ----------------------------------------------------
local listenHost = '127.0.0.1'
local listenPort = 4444
local smoothingTau = 0.06   -- seconds; time constant of the smoothing
                            -- filter (bigger = smoother but laggier)

-- State -------------------------------------------------------
local udp = nil
local enabled = true
local phoneQuat = nil       -- latest phone orientation (BeamNG frame)
local refQuat = nil         -- phone orientation captured at recenter
local camBase = nil         -- camera orientation captured at recenter
local currentQuat = nil     -- smoothed output orientation
local pendingRecenter = false
local packetsSeen = 0

-- Convert the phone's Y-up quaternion into BeamNG's Z-up frame.
-- Derivation in the header comment: (x, y, z, w) -> (x, -z, y, w).
local function phoneToBeamNG(q)
  return quat(q[1], -q[3], q[2], q[4])
end

-- Normalized linear interpolation between quaternions.
-- Good enough for frame-to-frame smoothing (angles are tiny);
-- the sign flip picks the shorter of the two arcs, since q and -q
-- represent the same rotation.
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

local function openSocket()
  if udp then udp:close() end
  udp = socket.udp()
  udp:setsockname(listenHost, listenPort)
  udp:settimeout(0)  -- non-blocking: never stall the render thread
  log('I', 'phoneCamera', string.format('listening on UDP %s:%d', listenHost, listenPort))
end

local function onExtensionLoaded()
  openSocket()
  log('I', 'phoneCamera', 'loaded. Enable free camera (Shift+C) and start streaming from your phone.')
  log('I', 'phoneCamera', 'console commands: extensions.phoneCamera.recenter() / setEnabled(bool) / setSmoothing(seconds) / setPort(n)')
end

local function onExtensionUnloaded()
  if udp then udp:close(); udp = nil end
end

-- Drain every datagram queued since last frame; only the newest
-- orientation matters (older ones are stale), but recenter requests
-- must never be dropped.
local function drainSocket()
  if not udp then return end
  for _ = 1, 128 do
    local data = udp:receive()
    if not data then break end
    local msg = jsonDecode(data)
    if msg then
      if msg.t == 'o' and type(msg.q) == 'table' and #msg.q == 4 then
        phoneQuat = phoneToBeamNG(msg.q)
        packetsSeen = packetsSeen + 1
        if packetsSeen == 1 then
          -- First packet ever: auto-recenter so the camera doesn't jump.
          pendingRecenter = true
        end
      elseif msg.t == 'recenter' then
        pendingRecenter = true
      end
    end
  end
end

local function onUpdate(dtReal)
  drainSocket()
  if not enabled or not phoneQuat then return end

  -- Only drive the free camera; leave orbit/chase/etc. alone.
  if not commands.isFreeCamera() then return end

  if pendingRecenter then
    pendingRecenter = false
    refQuat = phoneQuat
    camBase = getCameraQuat()
    currentQuat = camBase
    log('I', 'phoneCamera', 'recentered: phone pose mapped to current camera pose')
  end
  if not refQuat then return end

  -- Relative rotation since recenter, applied to the camera base
  -- (see header comment for why this composition order is correct).
  local target = camBase * (refQuat:inversed() * phoneQuat)

  -- Exponential smoothing, framerate-independent:
  -- t = 1 - e^(-dt/tau) converges to the target with time constant tau
  -- regardless of frame rate.
  local t = 1 - math.exp(-(dtReal or 0.016) / smoothingTau)
  currentQuat = currentQuat and nlerp(currentQuat, target, t) or target

  -- Keep the camera's position, replace only its rotation.
  local pos = getCameraPosition()
  setCameraPosRot(pos.x, pos.y, pos.z,
                  currentQuat.x, currentQuat.y, currentQuat.z, currentQuat.w)
end

-- Public API (console: extensions.phoneCamera.<fn>) ------------
M.recenter = function() pendingRecenter = true end

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
  openSocket()
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate

return M
