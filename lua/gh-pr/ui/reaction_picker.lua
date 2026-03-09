local config = require("gh-pr.config")
local reactions = require("gh-pr.reactions")

local M = {}

local active_pickers = {
  by_origin = {},
}

local picker_states = {}
local namespace = vim.api.nvim_create_namespace("gh_pr_reaction_picker")
local selection_namespace = vim.api.nvim_create_namespace("gh_pr_reaction_picker_selection")

local function clear_picker_state(bufnr)
  picker_states[bufnr] = nil
end

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function valid_buf(bufnr)
  return type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
  return type(winid) == "number" and winid > 0 and vim.api.nvim_win_is_valid(winid)
end

local function options()
  local line_comments = (config.get() or {}).line_comments or {}
  local reactions_cfg = type(line_comments.reactions) == "table" and line_comments.reactions or {}
  local picker = type(reactions_cfg.picker) == "table" and reactions_cfg.picker or {}
  return {
    render = safe_string(reactions_cfg.render, "emoji"),
    viewer_marker = safe_string(reactions_cfg.viewer_marker, "*"),
    position = safe_string(picker.position, "cursor"),
    border = safe_string(picker.border, "rounded"),
    enter = picker.enter ~= false,
    width = math.max(36, math.floor(tonumber(picker.width) or 56)),
    height = math.max(8, math.floor(tonumber(picker.height) or 10)),
  }
end

local function set_origin_picker_var(origin_bufnr, picker_win)
  if valid_buf(origin_bufnr) then
    vim.b[origin_bufnr].gh_pr_reaction_picker_win = picker_win
  end
end

local function clear_origin_picker_var(origin_bufnr)
  if valid_buf(origin_bufnr) then
    vim.b[origin_bufnr].gh_pr_reaction_picker_win = nil
  end
end

local function clear_origin_state(origin_bufnr)
  local picker_win = active_pickers.by_origin[origin_bufnr]
  if not picker_win then
    return
  end
  active_pickers.by_origin[origin_bufnr] = nil
  clear_origin_picker_var(origin_bufnr)
end

function M.close_for_origin(origin_bufnr)
  local picker_win = active_pickers.by_origin[origin_bufnr]
  local picker_buf = nil
  if valid_win(picker_win) then
    picker_buf = vim.api.nvim_win_get_buf(picker_win)
  else
    for bufnr, state in pairs(picker_states) do
      if type(state) == "table" and state.origin_bufnr == origin_bufnr then
        picker_buf = bufnr
        break
      end
    end
  end
  if valid_win(picker_win) then
    pcall(vim.api.nvim_win_close, picker_win, true)
  end
  if type(picker_buf) == "number" then
    clear_picker_state(picker_buf)
  end
  clear_origin_state(origin_bufnr)
end

local function popup_position(width, height, opts)
  local position = safe_string(opts.position, "editor")
  if position == "cursor" then
    return {
      relative = "cursor",
      row = 1,
      col = 1,
    }
  end

  local anchor_win = type(opts.anchor_win) == "number" and opts.anchor_win or nil
  if position == "preview_window" and valid_win(anchor_win) then
    local window_width = vim.api.nvim_win_get_width(anchor_win)
    local window_height = vim.api.nvim_win_get_height(anchor_win)
    local bounded_width = math.max(20, math.min(width, window_width))
    local bounded_height = math.max(6, math.min(height, window_height))
    return {
      relative = "win",
      win = anchor_win,
      row = math.max(0, math.floor((window_height - bounded_height) / 2)),
      col = math.max(0, math.floor((window_width - bounded_width) / 2)),
      width = bounded_width,
      height = bounded_height,
    }
  end

  return {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  }
end

local function fit_text(text, width)
  width = math.max(1, math.floor(width))
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end

  local ellipsis = width > 1 and "…" or ""
  local max_width = width - vim.fn.strdisplaywidth(ellipsis)
  local result = ""
  local chars = vim.fn.strchars(text)
  for index = 0, chars - 1 do
    local char = vim.fn.strcharpart(text, index, 1)
    if vim.fn.strdisplaywidth(result .. char) > max_width then
      break
    end
    result = result .. char
  end
  return result .. ellipsis
end

local function padded_cell_text(entry, cell_width)
  local text = fit_text(entry.display, cell_width)
  local padding = math.max(0, cell_width - vim.fn.strdisplaywidth(text))
  return text .. string.rep(" ", padding)
end

function M.build_layout(opts)
  opts = type(opts) == "table" and opts or {}

  local sections = type(opts.sections) == "table" and opts.sections or {}
  local width = math.max(36, math.floor(tonumber(opts.width) or 56))
  local columns = math.max(1, math.floor(tonumber(opts.columns) or 4))
  local gap = string.rep(" ", math.max(1, math.floor(tonumber(opts.gap) or 2)))
  local gap_width = #gap
  local cell_width = math.max(8, math.floor((width - ((columns - 1) * gap_width)) / columns))
  local lines = {}
  local items = {}
  local rows = {}
  local title_line = nil
  local footer_line = nil

  lines[#lines + 1] = safe_string(opts.title, "Add reaction")
  title_line = #lines
  lines[#lines + 1] = ""

  for _, section in ipairs(sections) do
    lines[#lines + 1] = safe_string(section.title, "Reactions")
    local row_line = #lines + 1
    local row_items = {}
    local line = ""

    for col, entry in ipairs(type(section.items) == "table" and section.items or {}) do
      if col > 1 then
        line = line .. gap
      end
      local start_col = #line
      local cell_text = padded_cell_text(entry, cell_width)
      line = line .. cell_text
      local item = vim.tbl_extend("force", {}, entry, {
        line = row_line,
        start_col = start_col,
        end_col = #line,
        column = col,
        row = #rows + 1,
      })
      items[#items + 1] = item
      row_items[#row_items + 1] = #items
    end

    lines[#lines + 1] = line
    rows[#rows + 1] = row_items
    lines[#lines + 1] = ""
  end

  local footer = safe_string(opts.footer, "<CR> select  q close  h/j/k/l move  <Tab> next")
  lines[#lines + 1] = footer
  footer_line = #lines

  return {
    lines = lines,
    items = items,
    rows = rows,
    title_line = title_line,
    footer_line = footer_line,
    cell_width = cell_width,
    width = width,
  }
end

local function apply_static_highlights(bufnr, layout)
  if not valid_buf(bufnr) then
    return
  end
  if type(layout.title_line) == "number" then
    pcall(vim.api.nvim_buf_add_highlight, bufnr, namespace, "Title", layout.title_line - 1, 0, -1)
  end
  if type(layout.footer_line) == "number" then
    pcall(vim.api.nvim_buf_add_highlight, bufnr, namespace, "Comment", layout.footer_line - 1, 0, -1)
  end
  for _, row in ipairs(layout.rows or {}) do
    if #row > 0 then
      local item = layout.items[row[1]]
      if type(item) == "table" and type(item.line) == "number" and item.line > 1 then
        pcall(vim.api.nvim_buf_add_highlight, bufnr, namespace, "Title", item.line - 1, 0, -1)
      end
    end
  end
end

local function render_selection(bufnr)
  local state = picker_states[bufnr]
  if type(state) ~= "table" or not valid_buf(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, selection_namespace, 0, -1)
  local item = state.layout.items[state.current_index]
  if type(item) ~= "table" then
    return
  end

  pcall(vim.api.nvim_buf_set_extmark, bufnr, selection_namespace, item.line - 1, item.start_col, {
    end_col = item.end_col,
    hl_group = "Visual",
    priority = 120,
    strict = false,
  })
end

local function set_cursor_to_current(bufnr)
  local state = picker_states[bufnr]
  if type(state) ~= "table" or not valid_win(state.winid) then
    return
  end
  local item = state.layout.items[state.current_index]
  if type(item) ~= "table" then
    return
  end
  pcall(vim.api.nvim_win_set_cursor, state.winid, { item.line, item.start_col })
  render_selection(bufnr)
end

local function row_and_column(state, index)
  for row_index, row in ipairs(state.layout.rows or {}) do
    for col_index, item_index in ipairs(row) do
      if item_index == index then
        return row_index, col_index
      end
    end
  end
  return nil, nil
end

function M.current_item(bufnr)
  local state = picker_states[bufnr]
  if type(state) ~= "table" then
    return nil
  end
  return state.layout.items[state.current_index]
end

function M.move(bufnr, direction)
  local state = picker_states[bufnr]
  if type(state) ~= "table" then
    return false
  end

  local row_index, col_index = row_and_column(state, state.current_index)
  if not row_index or not col_index then
    return false
  end

  local target = nil
  if direction == "left" then
    target = state.layout.rows[row_index][math.max(1, col_index - 1)]
  elseif direction == "right" then
    target = state.layout.rows[row_index][math.min(#state.layout.rows[row_index], col_index + 1)]
  elseif direction == "up" then
    local target_row = math.max(1, row_index - 1)
    local row = state.layout.rows[target_row]
    target = row[math.min(col_index, #row)]
  elseif direction == "down" then
    local target_row = math.min(#state.layout.rows, row_index + 1)
    local row = state.layout.rows[target_row]
    target = row[math.min(col_index, #row)]
  elseif direction == "next" then
    target = state.current_index + 1
    if target > #state.layout.items then
      target = 1
    end
  elseif direction == "prev" then
    target = state.current_index - 1
    if target < 1 then
      target = #state.layout.items
    end
  end

  if not target then
    return false
  end

  state.current_index = target
  set_cursor_to_current(bufnr)
  return true
end

function M.confirm(bufnr)
  local state = picker_states[bufnr]
  if type(state) ~= "table" then
    return false
  end
  local item = state.layout.items[state.current_index]
  if type(item) ~= "table" then
    return false
  end

  local on_select = state.on_select
  local origin_bufnr = state.origin_bufnr
  M.close_for_origin(origin_bufnr)
  if type(on_select) == "function" then
    on_select(item)
  end
  return true
end

local function setup_keymaps(bufnr, origin_bufnr)
  local function move(direction)
    return function()
      M.move(bufnr, direction)
    end
  end

  vim.keymap.set("n", "q", function()
    M.close_for_origin(origin_bufnr)
  end, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = "Close PR reaction picker",
  })
  vim.keymap.set("n", "<Esc>", function()
    M.close_for_origin(origin_bufnr)
  end, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = "Close PR reaction picker",
  })
  vim.keymap.set("n", "<CR>", function()
    M.confirm(bufnr)
  end, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = "Select PR reaction",
  })

  for _, mapping in ipairs({
    { "h", "left", "Move left in PR reaction picker" },
    { "<Left>", "left", "Move left in PR reaction picker" },
    { "l", "right", "Move right in PR reaction picker" },
    { "<Right>", "right", "Move right in PR reaction picker" },
    { "k", "up", "Move up in PR reaction picker" },
    { "<Up>", "up", "Move up in PR reaction picker" },
    { "j", "down", "Move down in PR reaction picker" },
    { "<Down>", "down", "Move down in PR reaction picker" },
    { "<Tab>", "next", "Next PR reaction" },
    { "<S-Tab>", "prev", "Previous PR reaction" },
  }) do
    vim.keymap.set("n", mapping[1], move(mapping[2]), {
      buffer = bufnr,
      silent = true,
      nowait = true,
      desc = mapping[3],
    })
  end
end

function M.open(opts)
  opts = type(opts) == "table" and opts or {}

  local picker_opts = options()
  local mode = safe_string(opts.mode, "add")
  local origin_bufnr = type(opts.origin_bufnr) == "number" and opts.origin_bufnr or vim.api.nvim_get_current_buf()
  local sections = reactions.build_picker_sections(type(opts.reaction_groups) == "table" and opts.reaction_groups or {}, {
    render = picker_opts.render,
    viewer_marker = picker_opts.viewer_marker,
    only_viewer = mode == "remove",
  })
  if vim.tbl_isempty(sections) then
    return false, mode == "remove" and "You do not have any reactions on this comment" or "No reactions available"
  end

  M.close_for_origin(origin_bufnr)

  local title = mode == "remove" and "Remove reaction" or "Add reaction"
  local layout = M.build_layout({
    title = title,
    sections = sections,
    width = picker_opts.width,
    footer = "<CR> select  q close  h/j/k/l move  <Tab> next",
  })

  local width = clamp(layout.width, 20, math.max(20, vim.o.columns - 2))
  local height = clamp(picker_opts.height, 6, math.max(6, vim.o.lines - vim.o.cmdheight - 2))
  local placement = popup_position(width, height, {
    position = picker_opts.position,
    anchor_win = opts.anchor_win,
  })
  local final_width = placement.width or width
  local final_height = placement.height or height

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(bufnr, "swapfile", false)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
  vim.api.nvim_buf_set_option(bufnr, "filetype", "gh_pr_reaction_picker")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, layout.lines)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  pcall(vim.api.nvim_set_option_value, "modified", false, { buf = bufnr })

  local winid = vim.api.nvim_open_win(bufnr, picker_opts.enter == true, {
    relative = placement.relative,
    win = placement.win,
    row = placement.row,
    col = placement.col,
    width = final_width,
    height = final_height,
    style = "minimal",
    border = picker_opts.border,
    focusable = true,
    noautocmd = true,
  })

  vim.api.nvim_win_set_option(winid, "wrap", false)
  vim.api.nvim_win_set_option(winid, "linebreak", false)
  vim.api.nvim_win_set_option(winid, "cursorline", false)
  vim.api.nvim_win_set_option(winid, "winhl", "NormalFloat:NormalFloat,FloatBorder:FloatBorder")

  picker_states[bufnr] = {
    origin_bufnr = origin_bufnr,
    bufnr = bufnr,
    winid = winid,
    layout = layout,
    current_index = 1,
    on_select = opts.on_select,
  }

  apply_static_highlights(bufnr, layout)
  setup_keymaps(bufnr, origin_bufnr)
  active_pickers.by_origin[origin_bufnr] = winid
  set_origin_picker_var(origin_bufnr, winid)
  set_cursor_to_current(bufnr)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(winid),
    once = true,
    callback = function(args)
      local closed = tonumber(args and args.match or "")
      if closed == winid then
        clear_origin_state(origin_bufnr)
        clear_picker_state(bufnr)
      end
    end,
  })

  if valid_buf(origin_bufnr) then
    vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload", "BufDelete" }, {
      buffer = origin_bufnr,
      once = true,
      callback = function()
        M.close_for_origin(origin_bufnr)
      end,
    })
  end

  return true, {
    bufnr = bufnr,
    winid = winid,
  }
end

return M
