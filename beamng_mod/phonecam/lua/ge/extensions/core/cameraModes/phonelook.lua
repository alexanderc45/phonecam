-- ============================================================
-- phonelook — any-camera VR-style head-look filter
--
-- A core_camera *filter* (isGlobal + isFilter + numeric runningOrder).
-- Dropping this file in /lua/ge/extensions/core/cameraModes/ is the
-- entire registration: camera.lua auto-discovers every *.lua there
-- (FS:findFiles, camera.lua:84-91) and, because isFilter is set, keeps
-- this object out of the C-key vehicle-cam cycle (camera.lua:520) while
-- running :update(data) every frame in ascending runningOrder AFTER the
-- active camera mode has written data.res (camera.lua:926-929).
--
-- We compose the phone's head-look onto whatever mode is active:
--   * rotation:  data.res.rot = data.res.rot * delta   (POST-multiply =
--     camera-LOCAL rotation, because data.res.rot maps camera-local ->
--     world; proof: camera.lua getForward 1569-1573). This is the
--     opposite order from trackir.lua, which pre-multiplies for a
--     world-frame rotation — do NOT copy trackir's order.
--   * position:  data.res.pos = data.res.pos + (data.res.rot * delta),
--     the trackir.lua translation pattern (local offset rotated into
--     world). Applied with the mode's base rot, before the head-look
--     rotation, so the offset stays in the recentered-camera frame.
--
-- All the phone state, smoothing and recenter logic lives in the
-- phoneCamera extension; this filter is a thin, self-guarding applier.
--
-- IMPORTANT (camera.lua:796-812): the filter loop runs AFTER
-- validateData(), so there is no engine-side NaN safety net here — a NaN
-- written into data.res.rot/pos puts the C++ camera in an unrecoverable
-- state. We self-guard every write with isnaninf().
-- ============================================================

local C = {}
C.__index = C

-- isnaninf is an engine global (used throughout camera.lua); keep a
-- local fallback so this file is safe to load/syntax-check standalone.
local isnaninf = isnaninf or function(x) return x ~= x or x == math.huge or x == -math.huge end

function C:init()
  self.isGlobal = true      -- one shared singleton; survives veh/level changes
  self.isFilter = true      -- excluded from per-vehicle cams (camera.lua:520)
  self.hidden = true        -- not shown in the Options UI camera list
  -- Running order (ascending) verified in-game: transition=0.2, trackir=0.5,
  -- fallback=0.6, gameengine=1. 'gameengine' is the step that pushes the
  -- composed camera into the C++ engine — anything AFTER it composes into a
  -- Lua table the renderer never sees (found the hard way: order 100 ran
  -- perfectly and moved nothing). We must run after trackir/fallback but
  -- strictly BEFORE gameengine.
  self.runningOrder = 0.7
end

function C:update(data)
  -- Heartbeat for debug(): proves core_camera discovered us and calls
  -- update each frame (counted before any early-return).
  local pc = extensions.phoneCamera
  if pc and pc._filterTick then pc._filterTick('tick') end

  -- Yield to real VR head-tracking (same guard trackir.lua uses).
  if data.openxrSessionRunning then return true end
  -- The legacy free-cam path in phoneCamera.lua owns the free camera via
  -- setCameraPosRot; skip it here so we never double-apply.
  if commands.isFreeCamera() then return true end

  if not pc or not pc.isEnabled() then return true end

  -- Snapshot the active mode's rotation BEFORE we touch it, so the
  -- position offset is rotated by the mode's frame (trackir order).
  local baseRot = data.res.rot

  -- ---- position (6DOF) -------------------------------------------------
  -- In-place writes (:setAdd/:set), matching how the game's own camera
  -- modes mutate data.res — safest against any aliasing of the res objects.
  local pd = pc.getPosDelta and pc.getPosDelta(data.dtReal)
  if pd then
    local off = baseRot * pd                  -- local offset -> world
    if not isnaninf(off:squaredLength()) then
      data.res.pos:setAdd(off)
    end
  end

  -- ---- rotation (head-look) -------------------------------------------
  -- getHeadLookDelta returns a WORLD-frame rigid delta (the phone's
  -- rotation since neutral, in the camera-aligned world frame) — so it is
  -- PRE-multiplied, trackir-style. Field-verified: the same frame mapping
  -- makes position perfect.
  local delta = pc.getHeadLookDelta(data.dtReal)
  if delta then
    local r = delta * baseRot                 -- PRE-multiply: world-frame
    if not isnaninf(r:squaredNorm()) then
      data.res.rot:set(r)
      if pc._filterTick then pc._filterTick('applied') end
    end
  end

  return true
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW (matches trackir.lua factory)
return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
