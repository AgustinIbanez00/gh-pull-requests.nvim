local M = {}

local function safe_neotree_callback(method)
  return function(args)
    if package.loaded["neo-tree"] == nil then
      return
    end

    local ok, integration = pcall(require, "gh-pr.integrations.neotree")
    if not ok then
      return
    end

    local handler = integration[method]
    if type(handler) == "function" then
      handler(args)
    end
  end
end

function M.build()
  return {
    {
      event = "FileType",
      opts = {
        pattern = "neo-tree",
        callback = safe_neotree_callback("handle_neotree_filetype"),
      },
    },
    {
      event = "DirChanged",
      opts = {
        callback = safe_neotree_callback("handle_dir_changed"),
      },
    },
    {
      event = { "BufEnter", "WinEnter", "FocusGained" },
      opts = {
        callback = safe_neotree_callback("handle_focus_event"),
      },
    },
  }
end

return M
