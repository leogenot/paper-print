local LrApplication = import "LrApplication"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrPrefs = import "LrPrefs"
local LrTasks = import "LrTasks"
local LrView = import "LrView"

local PaperModel = require "PaperModel"
local State = require "State"

local PARAM_KEYS = { "paper", "intensity", "rolloff", "tone" }
local WRITE_TIMEOUT = { timeout = 5 }

local function paramsFrom(t)
  local p = {}
  for _, k in ipairs(PARAM_KEYS) do p[k] = t[k] end
  return p
end

local function toneLabel(v)
  v = tonumber(v) or 0
  if v <= -60 then return "cool blue white, blue-black shadows"
  elseif v < -10 then return "slightly cool"
  elseif v <= 10 then return "neutral white"
  elseif v < 60 then return "slightly warm"
  end
  return "warm beige white, brown-black shadows"
end

-- Point curves need Process Version 2012 or later.
local function needsNewerProcess(photo)
  local pv = tonumber((photo:getDevelopSettings() or {}).ProcessVersion)
  return pv ~= nil and pv < 6.7
end

local function showDialog(context)
  local catalog = LrApplication.activeCatalog()
  local photos = catalog:getTargetPhotos()
  local active = catalog:getTargetPhoto()
  if not active or #photos == 0 then
    LrDialogs.message("Paper Print", "Select at least one photo first.", "info")
    return
  end

  -- Snapshot every target photo so Cancel can put everything back.
  local snapshots, oldProcess = {}, 0
  for _, photo in ipairs(photos) do
    local base, savedParams, current = State.baseFor(photo)
    snapshots[photo.localIdentifier] = {
      photo = photo, base = base, savedParams = savedParams,
      original = current, originalState = State.rawString(photo),
    }
    if needsNewerProcess(photo) then oldProcess = oldProcess + 1 end
  end
  local activeSnap = snapshots[active.localIdentifier]

  -- Start from the active photo's existing paper, else the last-used settings.
  local prefs = LrPrefs.prefsForPlugin()
  local start = activeSnap.savedParams or prefs.lastParams or PaperModel.DEFAULTS

  local props = LrBinding.makePropertyTable(context)
  for _, k in ipairs(PARAM_KEYS) do
    local v = start[k]
    if v == nil then v = PaperModel.DEFAULTS[k] end
    props[k] = v
  end
  props.look = PaperModel.lookFor(paramsFrom(props))
  props.livePreview = prefs.livePreview ~= false
  props.showOriginal = false
  props.scope = #photos == 1 and "Applies to the selected photo."
    or string.format("Live preview shows the active photo; Apply updates all %d selected photos.", #photos)
  props.warning = oldProcess > 0 and string.format(
    "%d photo%s use%s an old Process Version; update to the current version in Develop for the curves to apply.",
    oldProcess, oldProcess == 1 and "" or "s", oldProcess == 1 and "s" or "") or ""

  -- Look menu ↔ sliders: choosing a look sets the sliders; moving a slider away from
  -- a look shows "Custom".
  local syncing = false
  props:addObserver("look", function()
    if syncing or props.look == "custom" then return end
    for _, look in ipairs(PaperModel.LOOKS) do
      if look.id == props.look then
        syncing = true
        for _, k in ipairs(PARAM_KEYS) do props[k] = look[k] end
        syncing = false
      end
    end
  end)
  local function syncLook()
    if syncing then return end
    syncing = true
    props.look = PaperModel.lookFor(paramsFrom(props))
    syncing = false
  end

  -- Live preview: a small loop writes the latest values to the active photo,
  -- coalescing rapid slider moves into one catalog write.
  local dirty, open, busy, previewApplied = true, true, false, false
  local function markDirty() dirty = true end
  for _, k in ipairs(PARAM_KEYS) do
    props:addObserver(k, markDirty)
    props:addObserver(k, syncLook)
  end
  props:addObserver("livePreview", markDirty)
  props:addObserver("showOriginal", markDirty)

  local function restoreActive()
    catalog:withWriteAccessDo("Paper Print (original)", function()
      State.restore(active, activeSnap.original, activeSnap.originalState)
    end, WRITE_TIMEOUT)
  end

  LrTasks.startAsyncTask(function()
    while open do
      if dirty then
        dirty = false
        busy = true
        local ok = LrTasks.pcall(function()
          if props.livePreview and not props.showOriginal then
            local params = paramsFrom(props)
            catalog:withWriteAccessDo("Paper Print (preview)", function()
              State.apply(active, params, activeSnap.base)
            end, WRITE_TIMEOUT)
            previewApplied = true
          elseif previewApplied then
            restoreActive()
            previewApplied = false
          end
        end)
        busy = false
        if not ok then dirty = true end -- catalog busy; try again shortly
      end
      LrTasks.sleep(0.2)
    end
  end)

  local f = LrView.osFactory()
  local bind = LrView.bind
  local share = LrView.share

  local function hint(args)
    return f:row {
      f:spacer { width = share "labelWidth" },
      f:static_text {
        title = args.title, font = "<system/small>", width = 320,
      },
    }
  end

  local function sliderRow(label, key, min, max)
    return f:row {
      f:static_text { title = label, alignment = "right", width = share "labelWidth" },
      f:slider { value = bind(key), min = min, max = max, integral = true, width = 240 },
      f:edit_field { value = bind(key), min = min, max = max, precision = 0, width_in_digits = 4 },
    }
  end

  local lookItems = {}
  for _, look in ipairs(PaperModel.LOOKS) do
    lookItems[#lookItems + 1] = { title = look.title, value = look.id }
  end
  lookItems[#lookItems + 1] = { separator = true }
  lookItems[#lookItems + 1] = { title = "Custom", value = "custom" }

  local paperItems = {}
  for _, key in ipairs(PaperModel.PAPER_ORDER) do
    paperItems[#paperItems + 1] = { title = PaperModel.PAPERS[key].label, value = key }
  end

  local contents = f:column {
    bind_to_object = props,
    spacing = f:control_spacing(),

    f:row {
      f:static_text { title = "Look", alignment = "right", width = share "labelWidth" },
      f:popup_menu { items = lookItems, value = bind "look", width = 180 },
    },

    f:separator { fill_horizontal = 1 },

    f:row {
      f:static_text { title = "Paper", alignment = "right", width = share "labelWidth" },
      f:popup_menu { items = paperItems, value = bind "paper", width = 180 },
    },
    hint { title = bind { key = "paper", transform = function(v)
      if v == "matte" then return "Lifted, separated blacks; soft micro-contrast and a slight veil." end
      if v == "glossy" then return "Deep blacks, crisp contrast, richer colour." end
      return "Pearl/luster surface: rich blacks without glossy bite."
    end } },

    sliderRow("Paper intensity", "intensity", 0, 100),
    hint { title = "How strongly the paper character shapes contrast and depth." },

    sliderRow("Highlight roll-off", "rolloff", 0, 100),
    hint { title = "Compresses the brightest highlights the way photo paper does." },

    sliderRow("Paper tone", "tone", -100, 100),
    hint { title = bind { key = "tone", transform = function(v) return "Paper: " .. toneLabel(v) .. "." end } },

    f:separator { fill_horizontal = 1 },

    f:row {
      f:checkbox { title = "Live preview", value = bind "livePreview" },
      f:checkbox {
        title = "Show original", value = bind "showOriginal",
        enabled = bind "livePreview",
      },
      f:spacer { fill_horizontal = 1 },
      f:push_button {
        title = "Reset",
        action = function()
          for _, k in ipairs(PARAM_KEYS) do props[k] = PaperModel.DEFAULTS[k] end
        end,
      },
      f:push_button {
        title = "Save as Preset",
        action = function()
          LrTasks.startAsyncTask(function()
            local params = paramsFrom(props)
            -- Presets carry the curves only, built on a linear base, so applying one
            -- never overwrites the photo's own sliders.
            local full = PaperModel.developSettings(params, {})
            local settings = { ToneCurveName2012 = "Custom" }
            for _, key in ipairs(PaperModel.CURVE_KEYS) do settings[key] = full[key] end
            local name = PaperModel.describe(params)
            local ok, err = LrTasks.pcall(function()
              LrApplication.addDevelopPresetForPlugin(_PLUGIN, name, settings)
            end)
            if ok then
              LrDialogs.showBezel("Saved preset \"" .. name .. "\"")
            else
              LrDialogs.message("Paper Print", "Could not save the preset:\n" .. tostring(err), "warning")
            end
          end)
        end,
      },
    },
    f:static_text { title = bind "scope", font = "<system/small>", width = 440 },
    f:static_text {
      title = bind "warning", font = "<system/small/bold>", width = 440, height_in_lines = 2,
      visible = oldProcess > 0,
    },
  }

  local result = LrDialogs.presentModalDialog {
    title = "Paper Print",
    contents = contents,
    actionVerb = "Apply",
  }

  open = false
  while busy do LrTasks.sleep(0.05) end

  if result == "ok" then
    local params = paramsFrom(props)
    prefs.lastParams = params
    prefs.livePreview = props.livePreview
    catalog:withWriteAccessDo("Paper Print", function()
      for _, snap in pairs(snapshots) do
        State.apply(snap.photo, params, snap.base)
      end
    end, { timeout = 30 })
  else
    prefs.livePreview = props.livePreview
    if previewApplied then restoreActive() end
  end
end

LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext("PaperPrintDialog", function(context)
    LrDialogs.attachErrorDialogToFunctionContext(context)
    showDialog(context)
  end)
end)
