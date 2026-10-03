--[[
  PaperModel.lua — pure Lua (5.1 compatible), no Lightroom imports.

  Models a darkroom print with the paper's characteristic (D–logE) curve:

    scene value ──► relative log exposure ──► print density ──► reflectance ──► display value

  * Paper type sets the density range (Dmax) and the mid-tone contrast (gamma).
    Matte papers have a low Dmax (blacks never get truly black) and soft micro-contrast;
    glossy papers reach deep blacks with crisper contrast.
  * Intensity blends the paper response with the untouched image.
  * Highlight roll-off adds a smooth shoulder above a knee: the brightest tones are
    compressed into a slightly lowered paper white instead of clipping to display white.
  * Paper tone sets the paper base colour (cool blue ↔ warm beige), multiplied in linear
    light so it is strongest in the highlights, and the matching image tone (blue-black
    ↔ brown-black), which shows mostly in the shadows.
  * Curves are written as Lightroom points fitted against Lightroom's own spline
    (see M.spline), so what Lightroom draws matches the model to within half a level.

  Lightroom's curve axes are 0–255 in a gamma-encoded space; we treat that as sRGB-encoded.
]]

local M = {}

M.PAPERS = {
  -- range = Dmax (density of paper black), gamma = mid/highlight contrast,
  -- shadowContrast scales the slope into Dmax; the rest are slider offsets at intensity 100.
  -- Matte also gets a little negative Dehaze: the veiling glare of a matte surface.
  matte   = { label = "Matte",   range = 1.55, gamma = 1.12, shadowContrast = 1.10,
              saturation = -8, clarity = -12, texture = -8, dehaze = -6 },
  neutral = { label = "Neutral", range = 1.85, gamma = 1.24, shadowContrast = 1.18,
              saturation =  3, clarity =   3, texture =  0, dehaze =  0 },
  glossy  = { label = "Glossy",  range = 2.15, gamma = 1.36, shadowContrast = 1.25,
              saturation = 10, clarity =   9, texture =  5, dehaze =  3 },
}
M.PAPER_ORDER = { "matte", "neutral", "glossy" }

M.DEFAULTS = {
  paper = "neutral", intensity = 70, rolloff = 40, tone = 10,
}

-- Starting points offered in the dialog's Look menu.
M.LOOKS = {
  { id = "neutral",  title = "Neutral print",     paper = "neutral", intensity = 70, rolloff = 40, tone = 10 },
  { id = "fiber",    title = "Warm fiber matte",  paper = "matte",   intensity = 75, rolloff = 55, tone = 45 },
  { id = "softmatte",title = "Soft matte",        paper = "matte",   intensity = 55, rolloff = 70, tone = 15 },
  { id = "cream",    title = "Cream luster",      paper = "neutral", intensity = 80, rolloff = 50, tone = 60 },
  { id = "glossy",   title = "Deep glossy",       paper = "glossy",  intensity = 85, rolloff = 30, tone = 5 },
  { id = "cool",     title = "Cool glossy",       paper = "glossy",  intensity = 75, rolloff = 30, tone = -35 },
}

function M.lookFor(params)
  for _, look in ipairs(M.LOOKS) do
    if look.paper == params.paper and look.intensity == params.intensity
      and look.rolloff == params.rolloff and look.tone == params.tone then
      return look.id
    end
  end
  return "custom"
end

-- Paper base colours at tone = ±100, as sRGB 0–255.
M.WARM_WHITE = { 255, 245, 228 }
M.COOL_WHITE = { 236, 245, 255 }


local LN10 = math.log(10)
local MID_GREY = 0.18

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi end
  return v
end
M.clamp = clamp

local function lerp(a, b, t) return a + (b - a) * t end

function M.decode(v) -- sRGB encoded 0..1 -> linear
  v = clamp(v, 0, 1)
  if v <= 0.04045 then return v / 12.92 end
  return ((v + 0.055) / 1.055) ^ 2.4
end

function M.encode(v) -- linear -> sRGB encoded 0..1
  v = clamp(v, 0, 1)
  if v <= 0.0031308 then return v * 12.92 end
  return 1.055 * v ^ (1 / 2.4) - 0.055
end

local function log10(v) return math.log(v) / LN10 end

-- Smooth minimum / maximum (log-sum-exp), k = width of the bend in density units.
local function smin(a, b, k)
  local m = math.min(a, b)
  return m - k * math.log(1 + math.exp(-math.abs(a - b) / k))
end
local function smax(a, b, k)
  local m = math.max(a, b)
  return m + k * math.log(1 + math.exp(-math.abs(a - b) / k))
end

-- A small printing flare keeps log(0) finite and lifts the exposure floor slightly,
-- as stray enlarger light does.
local FLARE = 0.004
local function relLogE(lin) return log10((lin + FLARE) / (MID_GREY + FLARE)) end
local LOGE_BLACK = relLogE(0)
local LOGE_WHITE = relLogE(1)
local SHADOW_BEND = 0.10 -- paper reaches Dmax fairly abruptly

-- Deepest input value whose detail should still separate from paper black.
local LOGE_DETAIL = relLogE(M.decode(6 / 255))

-- Raw paper density: two straight lines through mid grey — a shadow slope chosen so
-- the deepest detail lands on Dmax (the printer's choice of paper grade) and the
-- paper's own highlight gamma — joined smoothly, then bent into Dmax and into paper
-- white. `offset` slides the exposure like printing time; `toe` is the highlight bend.
local function rawDensity(logE, offset, gS, gH, range, toe)
  local u = logE - offset
  local mid = -log10(MID_GREY)
  local dS, dH = mid - gS * u, mid - gH * u
  local d
  if gS < gH then d = smin(dS, dH, 0.12) else d = smax(dS, dH, 0.12) end
  d = smin(d, range, SHADOW_BEND)
  return smax(d, 0, toe)
end

-- Builds the paper transfer function f(x) for x,y in 0..1 (encoded), before intensity blending.
function M.paperFunction(paperKey, rolloff)
  local p = M.PAPERS[paperKey] or M.PAPERS.neutral
  local r = clamp((rolloff or 0) / 100, 0, 1)
  local range = p.range
  local gH = p.gamma
  local midLogE = relLogE(MID_GREY)
  local gS = (range - (-log10(MID_GREY))) / (midLogE - LOGE_DETAIL) * p.shadowContrast
  local toe = 0.08
  local function rawD(logE, offset) return rawDensity(logE, offset, gS, gH, range, toe) end

  -- Normalised so input black -> Dmax and input white -> paper white (density 0).
  local function densityFor(logE, offset)
    local db = rawD(LOGE_BLACK, offset)
    local dw = rawD(LOGE_WHITE, offset)
    local d = rawD(logE, offset)
    return (d - dw) / (db - dw) * range
  end

  -- Choose the exposure offset so 18 % grey prints as 18 % grey.
  local target = -log10(MID_GREY)
  local lo, hi = -1.5, 1.5
  for _ = 1, 60 do
    local mid = (lo + hi) / 2
    if densityFor(midLogE, mid) < target then lo = mid else hi = mid end
  end
  local offset = (lo + hi) / 2

  return function(x)
    if x <= 0 then return M.encode(10 ^ (-range)) end
    if x >= 1 then return M.shoulder(1, r) end
    local d = densityFor(relLogE(M.decode(x)), offset)
    return M.shoulder(M.encode(10 ^ (-d)), r)
  end
end

-- Highlight roll-off: above a knee the curve bends smoothly (slope-continuous)
-- into a slightly lowered paper white, so the brightest tones are compressed
-- rather than clipped. r = 0 leaves the curve untouched.
function M.shoulder(y, r)
  if r <= 0 then return y end
  local knee = 1 - 0.45 * r
  local white = 1 - 0.07 * r
  if y <= knee then return y end
  local t = math.min((y - knee) / (1 - knee), 1)
  local s = (1 - knee) / (white - knee) -- keeps slope 1 at the knee
  local h = s * t - (s - 1) * t * t
  return knee + (white - knee) * h
end

-- Lightroom / Camera Raw interpolate point curves with the DNG SDK spline
-- (dng_spline_solver): a cubic Hermite whose slope at each point is the
-- distance-weighted average of the neighbouring segment slopes. We use the same
-- spline to read the user's curves and to check the curves we write.
local function splineSlopes(X, Y)
  local n = #X
  local S = {}
  local A = X[2] - X[1]
  local B = (Y[2] - Y[1]) / A
  S[1] = B
  for j = 3, n do
    local C = X[j] - X[j - 1]
    local D = (Y[j] - Y[j - 1]) / C
    S[j - 1] = (B * C + D * A) / (A + C)
    A, B = C, D
  end
  S[n] = 2 * B - S[n - 1]
  S[1] = 2 * S[1] - S[2]
  return S
end

-- Returns an evaluator for a flat Lightroom curve {x1,y1,x2,y2,...} (0..255).
function M.spline(curve)
  if not curve or #curve < 4 then return function(x) return x end end
  local X, Y = {}, {}
  for i = 1, #curve, 2 do X[#X + 1] = curve[i]; Y[#Y + 1] = curve[i + 1] end
  local n = #X
  if n == 2 then
    return function(x)
      if x <= X[1] then return Y[1] elseif x >= X[2] then return Y[2] end
      return Y[1] + (Y[2] - Y[1]) * (x - X[1]) / (X[2] - X[1])
    end
  end
  local S = splineSlopes(X, Y)
  return function(x)
    if x <= X[1] then return Y[1] end
    if x >= X[n] then return Y[n] end
    local j = 2
    while X[j] < x do j = j + 1 end
    local x0, x1 = X[j - 1], X[j]
    local A = x1 - x0
    local t = (x - x0) / A
    local t2, t3 = t * t, t * t * t
    return Y[j - 1] * (2 * t3 - 3 * t2 + 1) + Y[j] * (-2 * t3 + 3 * t2)
      + A * (S[j - 1] * (t3 - 2 * t2 + t) + S[j] * (t3 - t2))
  end
end

function M.evalCurve(curve, x) return M.spline(curve)(x) end

local function round(v) return math.floor(v + 0.5) end

-- Fits Lightroom curve points to target values T[0..255] (0..255 floats): starts from
-- the end points and keeps adding the point where Lightroom's spline misses most,
-- until it is within `tolerance` levels or `maxPoints` is reached.
M.MAX_POINTS = 16
function M.fitCurve(T, tolerance, maxPoints)
  tolerance = tolerance or 0.5
  maxPoints = maxPoints or M.MAX_POINTS
  local xs = { 0, 128, 255 }
  local function build()
    local c, lastY = {}, -1
    for _, x in ipairs(xs) do
      local y = clamp(round(T[x]), 0, 255)
      if y < lastY then y = lastY end
      lastY = y
      c[#c + 1] = x
      c[#c + 1] = y
    end
    return c
  end
  local curve = build()
  while true do
    local f = M.spline(curve)
    local worstX, worstErr = nil, 0
    for x = 0, 255 do
      local err = math.abs(f(x) - T[x])
      if err > worstErr then
        -- keep points at least 3 apart so the spline cannot wiggle between them
        local ok = true
        for _, px in ipairs(xs) do
          if math.abs(px - x) < 3 then ok = false break end
        end
        if ok then worstX, worstErr = x, err end
      end
    end
    if not worstX or worstErr <= tolerance or #xs >= maxPoints then break end
    xs[#xs + 1] = worstX
    table.sort(xs)
    curve = build()
  end

  -- Refinement: greedy insertion can bunch points up. Nudge each interior point and
  -- keep any move that lowers the worst error, until nothing improves.
  local function maxError(c)
    local f = M.spline(c)
    local e = 0
    for x = 0, 255 do
      local d = math.abs(f(x) - T[x])
      if d > e then e = d end
    end
    return e
  end
  local best = maxError(curve)
  if best > tolerance then
    for _ = 1, 4 do
      local improved = false
      for i = 2, #xs - 1 do
        for _, step in ipairs({ -6, -3, -1, 1, 3, 6 }) do
          local nx = xs[i] + step
          if nx - xs[i - 1] >= 3 and xs[i + 1] - nx >= 3 then
            local old = xs[i]
            xs[i] = nx
            local candidate = build()
            local e = maxError(candidate)
            if e < best - 1e-9 then
              best, curve, improved = e, candidate, true
            else
              xs[i] = old
            end
          end
        end
      end
      if not improved or best <= tolerance then break end
    end
  end
  return curve
end

-- Master curve: paper response applied on top of the user's own curve (baseCurve).
function M.masterTargets(params, baseCurve)
  local f = M.paperFunction(params.paper, params.rolloff)
  local k = clamp((params.intensity or 0) / 100, 0, 1)
  local base = M.spline(baseCurve)
  local T = {}
  for x = 0, 255 do
    local b = clamp(base(x), 0, 255) / 255
    T[x] = 255 * (b + k * (f(b) - b))
  end
  return T
end

function M.masterCurve(params, baseCurve)
  return M.fitCurve(M.masterTargets(params, baseCurve))
end

-- Linear-light multiplier for each channel from the tone slider (-100 cool .. +100 warm).
function M.paperTint(tone)
  local t = clamp((tone or 0) / 100, -1, 1)
  local target = t >= 0 and M.WARM_WHITE or M.COOL_WHITE
  local a = math.abs(t)
  local m = {}
  for i = 1, 3 do
    m[i] = lerp(1, M.decode(target[i] / 255), a)
  end
  return m
end

-- Image tone: warm-tone emulsions print brownish-black (more blue density), cool-tone
-- emulsions print blue-black. Modelled as a small per-channel density scale at
-- tone = ±100, so it shows most in the shadows and fades toward paper white.
M.WARM_IMAGE_TONE = { -0.035, 0.0, 0.055 }
M.COOL_IMAGE_TONE = { 0.035, 0.010, -0.035 }

-- Paper colour for one channel of an encoded value (0..1):
-- reflectance = paper base × (image reflectance ^ channel density scale).
function M.paperColor(y, ch, tone)
  local t = clamp((tone or 0) / 100, -1, 1)
  local eps = (t >= 0 and M.WARM_IMAGE_TONE or M.COOL_IMAGE_TONE)[ch] * math.abs(t)
  local m = M.paperTint(tone)
  local lin = M.decode(y)
  if lin > 0 then lin = lin ^ (1 + eps) end
  return M.encode(lin * m[ch])
end

-- Per-channel curves (Red, Green, Blue): user's channel curve, then the paper colour.
function M.channelCurves(params, baseCurves)
  local result = {}
  for ch = 1, 3 do
    local base = M.spline(baseCurves and baseCurves[ch])
    local T = {}
    for x = 0, 255 do
      local b = clamp(base(x), 0, 255) / 255
      T[x] = 255 * M.paperColor(b, ch, params.tone)
    end
    result[ch] = M.fitCurve(T, 0.5, 12)
  end
  return result
end

-- Slider offsets (scaled by intensity) that carry the paper's surface character.
function M.sliderDeltas(params)
  local p = M.PAPERS[params.paper] or M.PAPERS.neutral
  local k = clamp((params.intensity or 0) / 100, 0, 1)
  return {
    Saturation = round(p.saturation * k),
    Clarity2012 = round(p.clarity * k),
    Texture = round(p.texture * k),
    Dehaze = round(p.dehaze * k),
  }
end

M.CURVE_KEYS = { "ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue" }
M.SLIDER_KEYS = { "Saturation", "Clarity2012", "Texture", "Dehaze" }
M.IDENTITY_CURVE = { 0, 0, 255, 255 }

-- Full develop-settings table. `base` holds the photo's own values for every key
-- (curves as flat tables, sliders as numbers); the paper is layered on top of them.
function M.developSettings(params, base)
  base = base or {}
  local settings = {}
  settings.ToneCurveName2012 = "Custom"
  settings.ToneCurvePV2012 = M.masterCurve(params, base.ToneCurvePV2012)
  local ch = M.channelCurves(params, { base.ToneCurvePV2012Red, base.ToneCurvePV2012Green, base.ToneCurvePV2012Blue })
  settings.ToneCurvePV2012Red = ch[1]
  settings.ToneCurvePV2012Green = ch[2]
  settings.ToneCurvePV2012Blue = ch[3]
  local deltas = M.sliderDeltas(params)
  for _, key in ipairs(M.SLIDER_KEYS) do
    settings[key] = clamp((base[key] or 0) + deltas[key], -100, 100)
  end
  return settings
end

function M.describe(params)
  local p = M.PAPERS[params.paper] or M.PAPERS.neutral
  local tone = params.tone or 0
  local toneText = tone == 0 and "0" or string.format("%+d", tone)
  return string.format("Paper Print %s %d · RO %d · Tone %s", p.label, params.intensity or 0, params.rolloff or 0, toneText)
end

return M
