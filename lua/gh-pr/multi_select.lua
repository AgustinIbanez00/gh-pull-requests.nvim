local styles = require("gh-pr.overview_styles")

local M = {}

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function normalize_key(value)
  return safe_string(value, ""):lower()
end

local function clamp(value, min_value, max_value)
  return math.max(min_value, math.min(max_value, value))
end

local function valid_win(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
end

local function valid_buf(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function sanitize_modal_window(winid)
  if not valid_win(winid) then
    return
  end

  pcall(vim.api.nvim_set_option_value, "scrollbind", false, { win = winid })
  pcall(vim.api.nvim_set_option_value, "cursorbind", false, { win = winid })
  pcall(vim.api.nvim_set_option_value, "diff", false, { win = winid })
end

local function normalize_items(items)
  local result = {}
  local seen = {}

  for index, item in ipairs(type(items) == "table" and items or {}) do
    local value = safe_string(item.value, safe_string(item.id, safe_string(item.label, tostring(index))))
    local key = normalize_key(value)
    if value ~= "" and key ~= "" and not seen[key] then
      seen[key] = true
      result[#result + 1] = {
        id = safe_string(item.id, value),
        value = value,
        label = safe_string(item.label, value),
        description = safe_string(item.description, ""),
        color = safe_string(item.color, ""),
        kind = safe_string(item.kind, "item"),
        selected = item.selected == true,
      }
    end
  end

  return result
end

local function compute_window_size(title, items, opts)
  local editor_width = math.max(80, vim.o.columns)
  local editor_height = math.max(14, vim.o.lines - vim.o.cmdheight - 1)
  local max_label_width = vim.fn.strdisplaywidth(title)

  for _, item in ipairs(items) do
    local suffix = item.kind == "team" and " (team)" or ""
    local line = string.format("[ ] %s%s", item.label, suffix)
    if item.description ~= "" then
      line = line .. " - " .. item.description
    end
    max_label_width = math.max(max_label_width, vim.fn.strdisplaywidth(line))
  end

  local min_width = tonumber(opts.min_width) or 64
  local max_width = tonumber(opts.max_width) or 150
  min_width = clamp(math.floor(min_width), 40, editor_width)
  max_width = clamp(math.floor(max_width), min_width, editor_width)

  local preferred_width = max_label_width + 6
  local width = clamp(preferred_width, min_width, max_width)

  local header_rows = 4
  local footer_rows = 1
  local content_rows = math.max(1, #items)
  local preferred_height = header_rows + content_rows + footer_rows
  local min_height = tonumber(opts.min_height) or 10
  local max_height = tonumber(opts.max_height) or 38
  min_height = clamp(math.floor(min_height), 8, editor_height)
  max_height = clamp(math.floor(max_height), min_height, editor_height)
  local height = clamp(preferred_height, min_height, max_height)

  return width, height
end

local function line_for_item(item)
  local checked = item.selected and "x" or " "
  local suffix = item.kind == "team" and " (team)" or ""
  local text = string.format("[%s] %s%s", checked, item.label, suffix)
  if item.description ~= "" then
    text = text .. " - " .. item.description
  end
  return text
end

local function render(state)
  if not valid_buf(state.bufnr) then
    return
  end

  local lines = {
    state.title,
    "Space: toggle | a: all | n: none | Enter: confirm | q: cancel",
    string.rep("=", math.max(16, math.min(state.width - 2, 80))),
    "",
  }

  state.first_item_line = #lines + 1
  for _, item in ipairs(state.items) do
    lines[#lines + 1] = line_for_item(item)
  end

  if #state.items == 0 then
    lines[#lines + 1] = "(no options available)"
  end

  lines[#lines + 1] = ""

  vim.api.nvim_buf_set_option(state.bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(state.bufnr, "modifiable", false)
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = state.bufnr })

  vim.api.nvim_buf_clear_namespace(state.bufnr, state.namespace, 0, -1)
  vim.api.nvim_buf_add_highlight(state.bufnr, state.namespace, "Title", 0, 0, -1)
  vim.api.nvim_buf_add_highlight(state.bufnr, state.namespace, "Comment", 1, 0, -1)
  vim.api.nvim_buf_add_highlight(state.bufnr, state.namespace, "Comment", 2, 0, -1)

  for index, item in ipairs(state.items) do
    local line = state.first_item_line + index - 1
    local prefix_group = item.selected and "DiffAdd" or "Comment"
    vim.api.nvim_buf_add_highlight(state.bufnr, state.namespace, prefix_group, line - 1, 0, 3)

    local label_start = 4
    local label_end = label_start + #item.label
    if item.kind == "label" then
      styles.ensure_base_highlights()
      local group = styles.ensure_label_highlight(item.color)
      vim.api.nvim_buf_add_highlight(state.bufnr, state.namespace, group, line - 1, label_start, label_end)
    elseif item.kind == "team" then
      vim.api.nvim_buf_add_highlight(state.bufnr, state.namespace, "Directory", line - 1, label_start, label_end)
    end
  end

  local item_count = #state.items
  local min_cursor = state.first_item_line
  local max_cursor = item_count > 0 and (state.first_item_line + item_count - 1) or state.first_item_line
  if valid_win(state.winid) then
    local cursor = vim.api.nvim_win_get_cursor(state.winid)
    local line = clamp(cursor[1], min_cursor, max_cursor)
    pcall(vim.api.nvim_win_set_cursor, state.winid, { line, 0 })
  end
end

local function close_window(state)
  if valid_win(state.winid) then
    pcall(vim.api.nvim_win_close, state.winid, true)
  end
end

local function restore_origin(state)
  if valid_win(state.origin_winid) then
    pcall(vim.api.nvim_set_current_win, state.origin_winid)
  end
end

local function finish(state, confirmed)
  if state.finished then
    return
  end
  state.finished = true

  close_window(state)
  restore_origin(state)

  if confirmed then
    local selected_values = {}
    local selected_items = {}
    for _, item in ipairs(state.items) do
      if item.selected then
        selected_values[#selected_values + 1] = item.value
        selected_items[#selected_items + 1] = item
      end
    end
    state.on_confirm(selected_values, selected_items)
    return
  end

  state.on_cancel()
end

local function current_item_index(state)
  if not valid_win(state.winid) then
    return nil
  end

  local cursor = vim.api.nvim_win_get_cursor(state.winid)
  local index = cursor[1] - state.first_item_line + 1
  if index < 1 or index > #state.items then
    return nil
  end
  return index
end

local function toggle_current_item(state)
  local index = current_item_index(state)
  if not index then
    return
  end

  local item = state.items[index]
  item.selected = not item.selected
  render(state)
end

local function select_all(state)
  for _, item in ipairs(state.items) do
    item.selected = true
  end
  render(state)
end

local function select_none(state)
  for _, item in ipairs(state.items) do
    item.selected = false
  end
  render(state)
end

local function setup_keymaps(state)
  local opts = {
    buffer = state.bufnr,
    silent = true,
    nowait = true,
  }

  vim.keymap.set("n", "<Space>", function()
    toggle_current_item(state)
  end, vim.tbl_extend("force", opts, { desc = "Toggle option" }))

  vim.keymap.set("n", "x", function()
    toggle_current_item(state)
  end, vim.tbl_extend("force", opts, { desc = "Toggle option" }))

  vim.keymap.set("n", "a", function()
    select_all(state)
  end, vim.tbl_extend("force", opts, { desc = "Select all options" }))

  vim.keymap.set("n", "n", function()
    select_none(state)
  end, vim.tbl_extend("force", opts, { desc = "Select no options" }))

  vim.keymap.set("n", "<CR>", function()
    finish(state, true)
  end, vim.tbl_extend("force", opts, { desc = "Confirm selection" }))

  vim.keymap.set("n", "q", function()
    finish(state, false)
  end, vim.tbl_extend("force", opts, { desc = "Cancel selection" }))

  vim.keymap.set("n", "<Esc>", function()
    finish(state, false)
  end, vim.tbl_extend("force", opts, { desc = "Cancel selection" }))
end

function M.open(opts)
  opts = type(opts) == "table" and opts or {}
  local items = normalize_items(opts.items)
  local title = safe_string(opts.title, "Select options")
  local on_confirm = type(opts.on_confirm) == "function" and opts.on_confirm or function() end
  local on_cancel = type(opts.on_cancel) == "function" and opts.on_cancel or function() end
  local origin_winid = vim.api.nvim_get_current_win()
  local width, height = compute_window_size(title, items, opts)
  local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
  local col = math.max(0, math.floor((vim.o.columns - width) / 2))

  local bufnr = vim.api.nvim_create_buf(false, true)
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = safe_string(opts.border, "rounded"),
    title = title,
    title_pos = "center",
    noautocmd = true,
  })

  sanitize_modal_window(winid)
  local state = {
    bufnr = bufnr,
    winid = winid,
    origin_winid = origin_winid,
    items = items,
    title = title,
    width = width,
    namespace = vim.api.nvim_create_namespace("gh-pr-multi-select"),
    first_item_line = 5,
    finished = false,
    on_confirm = on_confirm,
    on_cancel = on_cancel,
  }

  vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(bufnr, "swapfile", false)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  vim.api.nvim_buf_set_option(bufnr, "filetype", "ghpr_select")

  vim.api.nvim_win_set_option(winid, "number", false)
  vim.api.nvim_win_set_option(winid, "relativenumber", false)
  vim.api.nvim_win_set_option(winid, "cursorline", true)
  vim.api.nvim_win_set_option(winid, "wrap", false)
  vim.api.nvim_win_set_option(winid, "linebreak", false)
  vim.api.nvim_win_set_option(winid, "signcolumn", "no")
  vim.api.nvim_win_set_option(winid, "winhl", "NormalFloat:NormalFloat,FloatBorder:FloatBorder")

  setup_keymaps(state)
  render(state)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(winid),
    once = true,
    callback = function()
      if not state.finished then
        state.finished = true
        restore_origin(state)
        on_cancel()
      end
    end,
  })

  if #items > 0 then
    pcall(vim.api.nvim_win_set_cursor, winid, { state.first_item_line, 0 })
  end

  return bufnr, winid
end

return M
