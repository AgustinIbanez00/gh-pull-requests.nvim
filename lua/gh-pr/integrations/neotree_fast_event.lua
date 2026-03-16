local M = {}

local unpack_fn = table.unpack or unpack
local patched_managers = setmetatable({}, { __mode = "k" })

local function schedule_call(callback, ...)
  local args = { ... }
  vim.schedule(function()
    callback(unpack_fn(args))
  end)
end

function M.apply()
  local ok, manager = pcall(require, "neo-tree.sources.manager")
  if not ok or type(manager) ~= "table" then
    return false
  end

  if patched_managers[manager] then
    return true
  end

  local original_dispose = type(manager.dispose_invalid_tabs) == "function" and manager.dispose_invalid_tabs or nil
  local original_for_each_state = type(manager._for_each_state) == "function" and manager._for_each_state or nil
  if not original_dispose and not original_for_each_state then
    return false
  end

  if original_dispose then
    manager.dispose_invalid_tabs = function(...)
      if vim.in_fast_event() then
        schedule_call(original_dispose, ...)
        return
      end

      return original_dispose(...)
    end
  end

  if original_for_each_state then
    manager._for_each_state = function(...)
      if vim.in_fast_event() then
        schedule_call(original_for_each_state, ...)
        return
      end

      return original_for_each_state(...)
    end
  end

  patched_managers[manager] = true
  return true
end

return M
