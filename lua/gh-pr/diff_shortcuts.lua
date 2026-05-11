local M = {}

local ordered_actions = {
  "inline_comment",
  "inline_suggestion",
  "line_comments_popup",
  "refresh",
  "close_quick",
  "close_all_open_review",
  "help",
  "next_change",
  "prev_change",
  "next_file",
  "prev_file",
  "next_reviewed_file",
  "prev_reviewed_file",
  "toggle_whitespace",
  "cycle_whitespace_mode",
  "toggle_render_whitespace",
  "toggle_render_endlines",
  "cycle_mode",
  "set_vertical",
  "set_horizontal",
  "set_unified",
  "submit_pending_comment",
  "submit_pending_approve",
  "submit_pending_request_changes",
  "discard_pending_review",
  "toggle_review_tree",
  "toggle_comments_panel",
  "toggle_changes_panel",
  "image_default_action",
  "image_fallback_menu",
}

local action_modes = {
  inline_comment = { "n", "x" },
  inline_suggestion = { "n", "x" },
}

local codediff_reserved = {
  n = {
    ["q"] = true,
    ["g?"] = true,
    ["t"] = true,
    ["]c"] = true,
    ["[c"] = true,
    ["do"] = true,
    ["dp"] = true,
    ["gf"] = true,
    ["gm"] = true,
  },
  x = {},
}

M.defaults = {
  inline_comment = "<localleader>c",
  inline_suggestion = "<localleader>s",
  line_comments_popup = "<localleader>k",
  refresh = "<localleader>R",
  close_quick = "<localleader>q",
  close_all_open_review = "<localleader>Q",
  help = "<localleader>?",
  next_change = "<localleader>n",
  prev_change = "<localleader>p",
  next_file = "<localleader>f",
  prev_file = "<localleader>F",
  next_reviewed_file = "<localleader>v",
  prev_reviewed_file = "<localleader>V",
  toggle_whitespace = "",
  cycle_whitespace_mode = "",
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
  toggle_comments_panel = "<localleader>C",
  toggle_changes_panel = "<localleader>o",
  image_default_action = "<localleader>io",
  image_fallback_menu = "<localleader>im",
  show_open_hint = true,
}

M.legacy_defaults = {
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
  toggle_comments_panel = "<localleader>dc",
  toggle_changes_panel = "<localleader>do",
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

function M.action_modes(action)
  return action_modes[action] or { "n" }
end

function M.ordered_actions()
  return vim.deepcopy(ordered_actions)
end

function M.codediff_reserved_shortcuts()
  return vim.deepcopy(codediff_reserved)
end

function M.legacy_buffer_shortcuts(fallback)
  local expanded = M.expand_localleader(M.legacy_defaults, fallback)
  local shortcuts = {}
  local seen = {}

  for _, action in ipairs(ordered_actions) do
    local lhs = expanded[action]
    if type(lhs) == "string" and lhs ~= "" and not seen[lhs] then
      shortcuts[#shortcuts + 1] = lhs
      seen[lhs] = true
    end
  end

  return shortcuts
end

function M.resolve_effective(shortcuts, opts)
  opts = type(opts) == "table" and opts or {}

  local backend = type(opts.backend) == "string" and opts.backend or "virtual"
  local resolved = M.resolve(shortcuts)
  local expanded = M.expand_localleader(resolved, opts.localleader)
  local effective = vim.deepcopy(expanded)
  local diagnostics = {
    duplicates = {},
    reserved = {},
  }
  local seen = {}

  for _, action in ipairs(ordered_actions) do
    local lhs = expanded[action]
    local drop_action = false

    if type(lhs) == "string" and lhs ~= "" then
      for _, mode in ipairs(M.action_modes(action)) do
        local key = string.format("%s\0%s", mode, lhs)
        local previous = seen[key]

        if previous ~= nil and previous ~= action then
          effective[action] = ""
          diagnostics.duplicates[#diagnostics.duplicates + 1] = {
            mode = mode,
            lhs = lhs,
            kept = previous,
            skipped = action,
          }
          drop_action = true
          break
        end

        if backend == "codediff" and codediff_reserved[mode] and codediff_reserved[mode][lhs] then
          effective[action] = ""
          diagnostics.reserved[#diagnostics.reserved + 1] = {
            mode = mode,
            lhs = lhs,
            action = action,
          }
          drop_action = true
          break
        end

        seen[key] = action
      end
    end

    if drop_action then
      for _, mode in ipairs(M.action_modes(action)) do
        local key = string.format("%s\0%s", mode, lhs)
        if seen[key] == action then
          seen[key] = nil
        end
      end
    end
  end

  effective.show_open_hint = resolved.show_open_hint
  return effective, diagnostics
end

function M.notify_resolution_issues(diagnostics, opts)
  diagnostics = type(diagnostics) == "table" and diagnostics or {}
  opts = type(opts) == "table" and opts or {}

  local prefix = type(opts.prefix) == "string" and opts.prefix or "gh-pr diff shortcuts"

  for _, item in ipairs(diagnostics.duplicates or {}) do
    local message = string.format(
      "%s: skipped `%s` on %s `%s` because it conflicts with `%s`.",
      prefix,
      item.skipped,
      item.mode,
      item.lhs,
      item.kept
    )
    if vim.notify_once then
      vim.notify_once(message, vim.log.levels.WARN)
    else
      vim.notify(message, vim.log.levels.WARN)
    end
  end

  for _, item in ipairs(diagnostics.reserved or {}) do
    local message = string.format(
      "%s: skipped `%s` on %s `%s` because codediff owns that key.",
      prefix,
      item.action,
      item.mode,
      item.lhs
    )
    if vim.notify_once then
      vim.notify_once(message, vim.log.levels.WARN)
    else
      vim.notify(message, vim.log.levels.WARN)
    end
  end
end

return M
