local LrApplication = import "LrApplication"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrTasks = import "LrTasks"

local State = require "State"

-- Puts each selected photo back on the settings it had beneath the paper effect.
LrTasks.startAsyncTask(function()
  LrFunctionContext.callWithContext("RemovePaperPrint", function(context)
    LrDialogs.attachErrorDialogToFunctionContext(context)
    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos()

    local todo = {}
    for _, photo in ipairs(photos) do
      if State.read(photo) then
        local base = State.baseFor(photo)
        todo[#todo + 1] = { photo = photo, base = base }
      end
    end

    if #todo == 0 then
      LrDialogs.showBezel("No Paper Print on the selected photos")
      return
    end

    catalog:withWriteAccessDo("Remove Paper Print", function()
      for _, item in ipairs(todo) do
        State.restore(item.photo, item.base, nil)
      end
    end, { timeout = 30 })

    LrDialogs.showBezel(string.format("Removed Paper Print from %d photo%s", #todo, #todo == 1 and "" or "s"))
  end)
end)
