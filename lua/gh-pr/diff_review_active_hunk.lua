local M = {}

local namespace = vim.api.nvim_create_namespace("gh-pr-diff-review-active-hunk")
local timer = nil
local setup_done = false

local function valid_win(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
end

local function valid_buf(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function find_hunk_for_cursor(hunks, cursor_line, file_kind)
  if type(hunks) ~= "table" or #hunks == 0 then return nil end
  for _, hunk in ipairs(hunks) do
    local start_line, end_line
    if file_kind == "base" then
      start_line = hunk.base_start
      end_line = hunk.base_end
    elseif file_kind == "unified" then
      start_line = hunk.render_start or hunk.target_line
      end_line = hunk.render_end or hunk.target_line
    else
      start_line = hunk.head_start
      end_line = hunk.head_end
    end
    if start_line and end_line and cursor_line >= start_line and cursor_line <= end_line then
      return hunk
    end
  end
  return nil
end

local function find_neo_tree_panel_buf()
  local tabid = vim.api.nvim_get_current_tabpage()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabid)) do
    if valid_win(winid) then
      local bufnr = vim.api.nvim_win_get_buf(winid)
      if valid_buf(bufnr) then
        local ok, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
        if ok and ft == "neo-tree" then
          local ok2, source = pcall(function() return vim.b[bufnr].neo_tree_source end)
          if ok2 and source == "gh_pr_diff_review" then
            return bufnr, winid
          end
        end
      end
    end
  end
  return nil, nil
end

local function highlight_active_hunk()
  local config = require("gh-pr.config")
  local cfg = (config.get() or {}).diff_view or {}
  local rp = type(cfg.review_panel) == "table" and cfg.review_panel or {}
  local ah = type(rp.active_hunk_highlight) == "table" and rp.active_hunk_highlight or {}
  if ah.enabled == false then return end

  local current_buf = vim.api.nvim_get_current_buf()
  local kind = vim.b[current_buf].gh_pr_file_kind
  if kind ~= "base" and kind ~= "head" and kind ~= "unified" then return end

  local ok_source, source = pcall(require, "gh-pr.neotree.diff_review_source")
  if not ok_source then return end

  local tabid = vim.api.nvim_get_current_tabpage()
  local sessions = source._sessions
  local session = sessions and sessions[tabid]
  if type(session) ~= "table" or #(session.hunks or {}) == 0 then return end

  local panel_buf, _ = find_neo_tree_panel_buf()
  if not valid_buf(panel_buf) then return end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1]
  local active_hunk = find_hunk_for_cursor(session.hunks, cursor_line, kind)

  vim.api.nvim_buf_clear_namespace(panel_buf, namespace, 0, -1)
  if not active_hunk then return end

  -- Search for the hunk node text in the panel buffer
  local lines = vim.api.nvim_buf_get_lines(panel_buf, 0, -1, false)
  local target_fragment = string.format("L%d-", active_hunk.target_line or 0)

  for i, line_text in ipairs(lines) do
    if line_text:find(target_fragment, 1, true) then
      vim.api.nvim_buf_set_extmark(panel_buf, namespace, i - 1, 0, {
        end_col = #line_text,
        hl_group = "GhPrDiffReviewActiveHunk",
        priority = 100,
      })
      break
    end
  end
end

local function debounced_highlight()
  local config = require("gh-pr.config")
  local cfg = (config.get() or {}).diff_view or {}
  local rp = type(cfg.review_panel) == "table" and cfg.review_panel or {}
  local ah = type(rp.active_hunk_highlight) == "table" and rp.active_hunk_highlight or {}
  local debounce_ms = tonumber(ah.debounce_ms) or 80

  if timer then
    pcall(function() timer:stop() end)
  end
  timer = vim.defer_fn(function()
    timer = nil
    pcall(highlight_active_hunk)
  end, debounce_ms)
end

function M.attach()
  if setup_done then return end
  setup_done = true

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinEnter" }, {
    group = vim.api.nvim_create_augroup("GhPrDiffReviewActiveHunk", { clear = true }),
    desc = "gh-pr: highlight active hunk in diff review panel",
    callback = function()
      local current_buf = vim.api.nvim_get_current_buf()
      local kind = vim.b[current_buf].gh_pr_file_kind
      if kind ~= "base" and kind ~= "head" and kind ~= "unified" then return end
      debounced_highlight()
    end,
  })
end

return M
