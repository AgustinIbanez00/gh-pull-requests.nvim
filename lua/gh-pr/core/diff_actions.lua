local M = {}

local function navigate_codediff_hunk(step)
  if type(vim.b.gh_pr_diff_backend) ~= "string" or vim.b.gh_pr_diff_backend ~= "codediff" then
    return false
  end

  local ok_codediff, codediff = pcall(require, "codediff")
  if not ok_codediff then
    return false
  end

  if step > 0 and type(codediff.next_hunk) == "function" then
    local ok, moved = pcall(codediff.next_hunk)
    return ok and moved == true
  end
  if step < 0 and type(codediff.prev_hunk) == "function" then
    local ok, moved = pcall(codediff.prev_hunk)
    return ok and moved == true
  end

  return false
end

local function file_path(file)
  if type(file) ~= "table" then
    return nil
  end

  local path = file.path or file.filename
  if type(path) ~= "string" or path == "" then
    return nil
  end

  return path
end

local function current_file_path(state_module)
  if type(vim.b.gh_pr_path) == "string" and vim.b.gh_pr_path ~= "" then
    return vim.b.gh_pr_path
  end

  if type(state_module) ~= "table" or type(state_module.get_active_file) ~= "function" then
    return nil
  end

  return file_path(state_module.get_active_file())
end

local function ordered_pr_files(details)
  local entries = {}
  for _, file in ipairs(type(details.files) == "table" and details.files or {}) do
    local path = file_path(file)
    if path then
      entries[#entries + 1] = {
        file = file,
        path = path,
      }
    end
  end
  return entries
end

local function file_matches_filter(entry, repository, pr_number, reviewed_only, state_module)
  if not reviewed_only then
    return true
  end

  if type(repository) ~= "string" or repository == "" then
    return false
  end

  if type(state_module) ~= "table" or type(state_module.is_viewed) ~= "function" then
    return false
  end

  return state_module.is_viewed(repository, pr_number, entry.path)
end

local function pick_next_file(details, pr, step, reviewed_only, ctx)
  local entries = ordered_pr_files(details)
  if #entries == 0 then
    return nil, "Current PR has no files"
  end

  local repository = reviewed_only and ctx.normalize_repository(details) or nil
  if reviewed_only and not repository then
    return nil, "Unable to resolve repository for reviewed files"
  end

  local current_path = current_file_path(ctx.state)
  local current_index = nil
  if current_path then
    for index, entry in ipairs(entries) do
      if entry.path == current_path then
        current_index = index
        break
      end
    end
  end

  if current_index == nil then
    current_index = step > 0 and 0 or 1
  end

  local total = #entries
  for offset = 1, total do
    local index = ((current_index - 1) + (offset * step)) % total + 1
    local entry = entries[index]
    if file_matches_filter(entry, repository, pr.number, reviewed_only, ctx.state) then
      return entry.file, nil
    end
  end

  if reviewed_only then
    return nil, "No reviewed files found in this PR"
  end

  return nil, "Unable to resolve next file in PR"
end

local function open_file_for_navigation(file, ctx)
  local diff_view = ctx.current_diff_view_preferences()
  ctx.open_diff(file, {
    new_tab = false,
    view_mode = diff_view.mode,
    ignore_whitespace = diff_view.ignore_whitespace,
    render_whitespace = diff_view.render_whitespace,
    render_endlines = diff_view.render_endlines,
  })
end

function M.navigate_files(step, reviewed_only, ctx)
  local pr, details, err = ctx.resolve_active_pr()
  if not pr then
    return ctx.notify_error(err)
  end

  local target, target_err = pick_next_file(details, pr, step, reviewed_only, ctx)
  if not target then
    return ctx.notify_error(target_err)
  end

  open_file_for_navigation(target, ctx)
end

function M.next_file(ctx)
  M.navigate_files(1, false, ctx)
end

function M.prev_file(ctx)
  M.navigate_files(-1, false, ctx)
end

function M.next_reviewed_file(ctx)
  M.navigate_files(1, true, ctx)
end

function M.prev_reviewed_file(ctx)
  M.navigate_files(-1, true, ctx)
end

local function goto_unified_change(step)
  if navigate_codediff_hunk(step) then
    return
  end

  if vim.wo.diff then
    vim.cmd(step > 0 and "normal! ]c" or "normal! [c")
    return
  end

  if vim.b.gh_pr_file_kind ~= "unified" then
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local first = step > 0 and (cursor[1] + 1) or (cursor[1] - 1)
  local last = step > 0 and line_count or 1

  for line = first, last, step do
    local text = (vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or "")
    if vim.startswith(text, "+ ") or vim.startswith(text, "- ") then
      vim.api.nvim_win_set_cursor(0, { line, 0 })
      return
    end
  end
end

function M.next_change()
  goto_unified_change(1)
end

function M.prev_change()
  goto_unified_change(-1)
end

return M
