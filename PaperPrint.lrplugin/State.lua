--[[
  State.lua — reads/writes the per-photo paper state and works out the "base"
  (the photo's own settings beneath the paper effect).

  state = {
    params  = { paper, intensity, rolloff, tone },
    base    = { [key] = value },   -- photo's own values before the paper
    applied = { [key] = value },   -- what the plugin last wrote
  }

  On reopen, a key whose current value still equals `applied` is assumed untouched
  since, so its stored base is reused. If the user changed it in Develop afterwards,
  the current value becomes the new base.
]]

local PaperModel = require "PaperModel"

local State = {}

State.KEYS = {}
for _, k in ipairs(PaperModel.CURVE_KEYS) do State.KEYS[#State.KEYS + 1] = k end
for _, k in ipairs(PaperModel.SLIDER_KEYS) do State.KEYS[#State.KEYS + 1] = k end
State.KEYS[#State.KEYS + 1] = "ToneCurveName2012"

------------------------------------------------------------------ serialisation
local function serialize(v)
  local t = type(v)
  if t == "number" then
    return string.format("%.17g", v)
  elseif t == "string" then
    return string.format("%q", v)
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "table" then
    local parts = {}
    local n = #v
    for i = 1, n do parts[#parts + 1] = serialize(v[i]) end
    for k, val in pairs(v) do
      if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then
        parts[#parts + 1] = "[" .. serialize(k) .. "]=" .. serialize(val)
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "nil"
end
State.serialize = serialize

local function deserialize(s)
  if type(s) ~= "string" or s == "" then return nil end
  local fn = loadstring("return " .. s)
  if not fn then return nil end
  setfenv(fn, {})
  local ok, v = pcall(fn)
  if ok and type(v) == "table" then return v end
  return nil
end

------------------------------------------------------------------ helpers
local function copy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, val in pairs(v) do t[k] = copy(val) end
  return t
end
State.copy = copy

local function equal(a, b)
  if type(a) ~= type(b) then
    -- nil and an identity curve / zero slider mean the same thing
    return false
  end
  if type(a) ~= "table" then
    if type(a) == "number" then return math.abs(a - b) < 1e-6 end
    return a == b
  end
  if #a ~= #b then return false end
  for i = 1, #a do
    if math.abs(a[i] - b[i]) > 1e-6 then return false end
  end
  return true
end

local function normalize(key, v)
  if key:find("^ToneCurvePV2012") then
    if type(v) ~= "table" or #v < 4 then return copy(PaperModel.IDENTITY_CURVE) end
    return copy(v)
  elseif key == "ToneCurveName2012" then
    return v or "Linear"
  end
  return tonumber(v) or 0
end

------------------------------------------------------------------ public API
function State.read(photo)
  local ok, raw = pcall(function() return photo:getPropertyForPlugin(_PLUGIN, "state") end)
  if not ok then return nil end
  return deserialize(raw), raw
end

function State.rawString(photo)
  local ok, raw = pcall(function() return photo:getPropertyForPlugin(_PLUGIN, "state") end)
  return ok and raw or nil
end

-- Current values of every key the plugin touches (normalised).
function State.currentValues(photo)
  local dev = photo:getDevelopSettings() or {}
  local values = {}
  for _, key in ipairs(State.KEYS) do values[key] = normalize(key, dev[key]) end
  return values
end

-- The photo's own settings beneath any earlier paper effect, plus earlier params.
function State.baseFor(photo)
  local current = State.currentValues(photo)
  local saved = State.read(photo)
  local base = {}
  for _, key in ipairs(State.KEYS) do
    if saved and saved.base and saved.applied
      and saved.applied[key] ~= nil and equal(current[key], saved.applied[key]) then
      base[key] = normalize(key, saved.base[key])
    else
      base[key] = current[key]
    end
  end
  -- The curve name must match the curve, or Lightroom may swap in a named preset curve.
  base.ToneCurveName2012 = equal(base.ToneCurvePV2012, PaperModel.IDENTITY_CURVE) and "Linear" or "Custom"
  return base, saved and saved.params or nil, current
end

-- Must be called inside catalog:withWriteAccessDo.
function State.apply(photo, params, base)
  local settings = PaperModel.developSettings(params, base)
  photo:applyDevelopSettings(settings)
  photo:setPropertyForPlugin(_PLUGIN, "state", serialize({
    params = copy(params),
    base = base,
    applied = settings,
  }))
  return settings
end

-- Must be called inside catalog:withWriteAccessDo.
function State.restore(photo, values, rawState)
  photo:applyDevelopSettings(values)
  photo:setPropertyForPlugin(_PLUGIN, "state", rawState)
end

return State
