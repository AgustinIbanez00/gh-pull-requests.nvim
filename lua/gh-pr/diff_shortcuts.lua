local M = {}

M.defaults = {
  inline_comment = "<localleader>ic",
  inline_suggestion = "<localleader>is",
  line_comments_popup = "<localleader>dk",
  refresh = "<localleader>dr",
  close_quick = "<localleader>dq",
  close_all_open_review = "<localleader>dQ",
  help = "<localleader>d?",
  next_change = "<localleader>dn",
  prev_change = "<localleader>dp",
  next_file = "<localleader>df",
  prev_file = "<localleader>dF",
  next_reviewed_file = "<localleader>dv",
  prev_reviewed_file = "<localleader>dV",
  toggle_whitespace = "",
  toggle_render_whitespace = "",
  toggle_render_endlines = "",
  cycle_mode = "",
  set_vertical = "",
  set_horizontal = "",
  set_unified = "",
  submit_pending_comment = "<localleader>rc",
  submit_pending_approve = "<localleader>ra",
  submit_pending_request_changes = "<localleader>rr",
  discard_pending_review = "<localleader>rd",
  toggle_review_tree = "<localleader>rx",
  toggle_comments_panel = "<localleader>dc",
  image_default_action = "<localleader>io",
  image_fallback_menu = "<localleader>im",
  show_open_hint = true,
}

function M.resolve(shortcuts)
  local source = type(shortcuts) == "table" and shortcuts or {}
  local resolved = {}
  for key, fallback in pairs(M.defaults) do
    if type(fallback) == "boolean" then
      if type(source[key]) == "boolean" then
        resolved[key] = source[key]
      else
        resolved[key] = fallback
      end
    else
      resolved[key] = type(source[key]) == "string" and source[key] or fallback
    end
  end
  return resolved
end

local function resolve_localleader(fallback)
  if type(fallback) == "string" and fallback ~= "" then
    return fallback
  end

  local configured = type(vim.g.maplocalleader) == "string" and vim.g.maplocalleader or ""
  if configured ~= "" then
    return configured
  end

  -- Avoid Neovim default "\" when maplocalleader is unset.
  return ","
end

function M.expand_localleader(shortcuts, fallback)
  local source = type(shortcuts) == "table" and shortcuts or {}
  local localleader = resolve_localleader(fallback)
  local expanded = {}

  for key, value in pairs(source) do
    if type(value) == "string" then
      expanded[key] = value:gsub("<[Ll]ocal[Ll]eader>", function()
        return localleader
      end)
    else
      expanded[key] = value
    end
  end

  return expanded
end

return M
