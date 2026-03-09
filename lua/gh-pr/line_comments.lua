local M = {}

local comment_thread_actions = require("gh-pr.comment_thread_actions")
local comment_popup = require("gh-pr.comment_popup")
local config = require("gh-pr.config")
local highlights = require("gh-pr.highlights")

local namespace = vim.api.nvim_create_namespace("gh-pr-line-comments")
local sign_group = "gh_pr_line_comments"

local sign_names = {
  open = "GhPrCommentSignOpen",
  resolved = "GhPrCommentSignResolved",
  outdated = "GhPrCommentSignOutdated",
}

local hl_groups = {
  open = "GhPrCommentLineOpen",
  resolved = "GhPrCommentLineResolved",
  outdated = "GhPrCommentLineOutdated",
}

local virt_hl_groups = {
  open = "GhPrCommentVirtOpen",
  resolved = "GhPrCommentVirtResolved",
  outdated = "GhPrCommentVirtOutdated",
}

local function notify_info(message)
  vim.notify(message, vim.log.levels.INFO)
end

local function safe_string(value, fallback)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return fallback or ""
end

local function normalize_paths(primary, alternatives)
  local seen = {}
  local ordered = {}

  local function add(path)
    if type(path) ~= "string" or path == "" then
      return
    end
    if seen[path] then
      return
    end
    seen[path] = true
    ordered[#ordered + 1] = path
  end

  add(primary)
  for _, path in ipairs(type(alternatives) == "table" and alternatives or {}) do
    add(path)
  end

  return ordered
end

local function infer_side(bufnr, ctx)
  if type(ctx.side) == "string" and (ctx.side == "base" or ctx.side == "head") then
    return ctx.side
  end

  local buffer_side = vim.b[bufnr].gh_pr_comment_side
  if type(buffer_side) == "string" and (buffer_side == "base" or buffer_side == "head") then
    return buffer_side
  end

  local file_kind = vim.b[bufnr].gh_pr_file_kind
  if file_kind == "base" then
    return "base"
  end
  if file_kind == "head" then
    return "head"
  end

  return nil
end

local function entry_key(entry)
  return table.concat({
    safe_string(entry.thread_id, ""),
    safe_string(entry.comment_id, ""),
    safe_string(entry.author, ""),
    safe_string(entry.created_at, ""),
    safe_string(entry.body, ""),
  }, ":")
end

local function collect_line_map(index, side, primary_path, alternatives)
  local line_map = {}
  local dedup = {}
  local paths = normalize_paths(primary_path, alternatives)

  for _, path in ipairs(paths) do
    local by_path = index[path]
    local side_map = by_path and by_path[side] or nil
    if type(side_map) == "table" then
      for line, entries in pairs(side_map) do
        local line_number = tonumber(line)
        if line_number and line_number >= 1 and type(entries) == "table" then
          line_map[line_number] = line_map[line_number] or {}
          dedup[line_number] = dedup[line_number] or {}
          for _, entry in ipairs(entries) do
            local key = entry_key(entry)
            if not dedup[line_number][key] then
              dedup[line_number][key] = true
              line_map[line_number][#line_map[line_number] + 1] = vim.deepcopy(entry)
            end
          end
        end
      end
    end
  end

  for _, entries in pairs(line_map) do
    table.sort(entries, function(left, right)
      local left_key = safe_string(left.created_at, "") .. ":" .. safe_string(left.comment_id, "")
      local right_key = safe_string(right.created_at, "") .. ":" .. safe_string(right.comment_id, "")
      return left_key < right_key
    end)
  end

  return line_map
end

local function marker_kind(entries)
  local has_open = false
  local has_outdated = false

  for _, entry in ipairs(entries or {}) do
    if entry.is_outdated then
      has_outdated = true
    end
    if not entry.is_resolved and not entry.is_outdated then
      has_open = true
    end
  end

  if has_open then
    return "open"
  end
  if has_outdated then
    return "outdated"
  end
  return "resolved"
end

local function line_entry_state(entry)
  if entry.is_pending then
    return "PENDING"
  end
  if entry.is_resolved then
    return "RESOLVED"
  end
  if entry.is_outdated then
    return "OUTDATED"
  end
  return "OPEN"
end

local function ensure_highlights()
  highlights.ensure_baseline_links()
end

local function ensure_signs(sign_config)
  local open_text = safe_string(sign_config.open, "C>")
  local resolved_text = safe_string(sign_config.resolved, "C=")
  local outdated_text = safe_string(sign_config.outdated, "C~")

  vim.fn.sign_define(sign_names.open, { text = open_text, texthl = "DiagnosticHint" })
  vim.fn.sign_define(sign_names.resolved, { text = resolved_text, texthl = "DiffAdd" })
  vim.fn.sign_define(sign_names.outdated, { text = outdated_text, texthl = "WarningMsg" })
end

local function indicator_style_flags(style)
  local normalized = safe_string(style, "sign_and_virtual_text")
  return {
    sign = normalized == "sign_only"
      or normalized == "sign_and_highlight"
      or normalized == "sign_and_virtual_text",
    highlight = normalized == "highlight_only" or normalized == "sign_and_highlight",
    virtual_text = normalized == "virtual_text_only" or normalized == "sign_and_virtual_text",
  }
end

local function virtual_text_options(lc_config)
  local source = type(lc_config.virtual_text) == "table" and lc_config.virtual_text or {}
  return {
    enabled = source.enabled ~= false,
    prefix = safe_string(source.prefix, "C"),
    show_count = source.show_count ~= false,
    show_authors = source.show_authors ~= false,
    max_authors = math.max(1, math.floor(tonumber(source.max_authors) or 2)),
    position = source.position == "inline" and "inline" or "eol",
  }
end

local function normalize_author_login(author)
  local login = vim.trim(safe_string(author, ""))
  if login == "" then
    return ""
  end
  if login:sub(1, 1) == "@" then
    login = login:sub(2)
  end
  return vim.trim(login)
end

local function build_count_virtual_label(entries, vt_opts)
  local label = vt_opts.prefix
  if vt_opts.show_count then
    label = string.format("%s x%d", label, #entries)
  end
  if label == "" then
    label = string.format("x%d", #entries)
  end
  return label
end

local function build_authors_virtual_label(entries, vt_opts)
  if type(entries) ~= "table" or vim.tbl_isempty(entries) then
    return ""
  end

  local seen = {}
  local selected = {}
  local unique_total = 0
  local max_authors = math.max(1, math.floor(tonumber(vt_opts.max_authors) or 2))

  for index = #entries, 1, -1 do
    local entry = entries[index]
    local login = normalize_author_login(type(entry) == "table" and entry.author or "")
    if login ~= "" and login ~= "unknown" then
      local dedup_key = login:lower()
      if not seen[dedup_key] then
        seen[dedup_key] = true
        unique_total = unique_total + 1
        if #selected < max_authors then
          selected[#selected + 1] = "@" .. login
        end
      end
    end
  end

  if unique_total == 0 or #selected == 0 then
    return ""
  end

  local label = "💬 " .. table.concat(selected, ", ")
  local remaining = unique_total - #selected
  if remaining > 0 then
    label = string.format("%s +%d", label, remaining)
  end
  return label
end

local function build_multiline_progress_label(entries, vt_opts)
  if type(entries) ~= "table" or vim.tbl_isempty(entries) then
    return ""
  end

  if #entries > 1 then
    return string.format("💬 %d comments", #entries)
  end

  local entry = entries[1]
  if type(entry) ~= "table" then
    return ""
  end

  local range_length = math.floor(tonumber(entry.range_length) or 0)
  local range_index = math.floor(tonumber(entry.range_index) or 0)
  if range_length < 2 or range_index < 1 then
    return ""
  end

  if range_index > range_length then
    range_index = range_length
  end

  local label = string.format("💬 L%d/%d", range_index, range_length)
  if vt_opts.show_authors then
    local login = normalize_author_login(entry.author)
    if login ~= "" and login:lower() ~= "unknown" then
      label = string.format("%s @%s", label, login)
    end
  end

  return label
end

local function popup_options(bufnr, lc_config)
  local popup_cfg = type(lc_config.popup) == "table" and lc_config.popup or {}
  local fallback_width = tonumber(lc_config.max_popup_width) or 90
  local fallback_height = tonumber(lc_config.max_popup_height) or 18
  local width = tonumber(vim.b[bufnr].gh_pr_comment_popup_width) or tonumber(popup_cfg.max_width) or fallback_width
  local height = tonumber(vim.b[bufnr].gh_pr_comment_popup_height) or tonumber(popup_cfg.max_height) or fallback_height

  return {
    enter = popup_cfg.enter ~= false,
    position = safe_string(popup_cfg.position, "cursor"),
    border = safe_string(popup_cfg.border, "rounded"),
    wrap = popup_cfg.wrap ~= false,
    close_on_move = popup_cfg.close_on_move ~= false,
    max_width = math.max(20, math.floor(width)),
    max_height = math.max(6, math.floor(height)),
  }
end

local function line_popup_items(entries, meta)
  meta = type(meta) == "table" and meta or {}
  local items = {}
  for _, entry in ipairs(entries or {}) do
    items[#items + 1] = {
      id = safe_string(entry.comment_id, ""),
      marker = " ",
      state = line_entry_state(entry),
      author = safe_string(entry.author, "unknown"),
      created_at = safe_string(entry.created_at, "-"),
      body = safe_string(entry.body, "(empty comment)"),
      url = safe_string(entry.url, ""),
      meta = {
        pr_number = tonumber(meta.pr_number),
        thread_id = safe_string(entry.thread_id, ""),
        path = safe_string(entry.path, safe_string(meta.path, "")),
        line = tonumber(entry.line) or tonumber(meta.line),
        original_line = tonumber(entry.original_line) or tonumber(meta.original_line),
        comment_id = safe_string(entry.comment_id, ""),
        comment_database_id = tonumber(entry.comment_database_id) or tonumber(entry.database_id),
        comment_author = safe_string(entry.author, "unknown"),
        comment_body = safe_string(entry.body, ""),
        comment_state = safe_string(entry.state, ""),
        viewer_did_author = entry.viewer_did_author == true,
        reaction_groups = type(entry.reaction_groups) == "table" and vim.deepcopy(entry.reaction_groups) or {},
        comment_is_pending = entry.is_pending == true,
        thread_is_resolved = entry.is_resolved == true,
        thread_is_outdated = entry.is_outdated == true,
      },
    }
  end
  return items
end

function M.clear_buffer(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  comment_popup.close_for_origin(bufnr, "line")
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  pcall(vim.fn.sign_unplace, sign_group, { buffer = bufnr })
  vim.b[bufnr].gh_pr_line_comments = {}
end

local function line_entries(bufnr, line)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "No PR comments available for this buffer"
  end

  local line_map = vim.b[bufnr].gh_pr_line_comments
  if type(line_map) ~= "table" then
    return nil, "No PR comments available for this buffer"
  end

  local entries = line_map[line]
  if type(entries) ~= "table" or vim.tbl_isempty(entries) then
    return nil, "No PR comments for the current line"
  end

  return entries, nil
end

function M.show_at_line(bufnr, line, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = type(opts) == "table" and opts or {}

  local entries, err = line_entries(bufnr, line)
  if not entries then
    if opts.notify_empty ~= false and type(err) == "string" and err ~= "" then
      notify_info(err)
    end
    return false
  end

  local lc_config = (config.get() or {}).line_comments or {}
  local popup_cfg = popup_options(bufnr, lc_config)
  local path = safe_string(vim.b[bufnr].gh_pr_path, "?")
  local anchor_win = vim.api.nvim_get_current_win()
  local popup_context = {
    pr_number = tonumber(vim.b[bufnr].gh_pr_number),
    path = path,
    line = tonumber(line),
  }
  local popup_actions = comment_thread_actions.build_popup_actions(popup_context)

  local ok, err = comment_popup.open({
    origin_bufnr = bufnr,
    tag = "line",
    title = string.format("PR line comments (%d)", #entries),
    location = string.format("%s:%d", path, line),
    items = line_popup_items(entries, {
      pr_number = tonumber(vim.b[bufnr].gh_pr_number),
      path = path,
      line = tonumber(line),
    }),
    actions = popup_actions,
    footer_provider = comment_thread_actions.build_popup_footer_provider(popup_context),
    mode = popup_cfg.enter and "open" or "preview",
    anchor_win = anchor_win,
    enter = popup_cfg.enter,
    position = popup_cfg.position,
    border = popup_cfg.border,
    wrap = popup_cfg.wrap,
    min_width = 40,
    min_height = 6,
    max_width = popup_cfg.max_width,
    max_height = popup_cfg.max_height,
    close_on_origin_move = (not popup_cfg.enter) and popup_cfg.close_on_move,
  })

  if not ok and err then
    vim.notify("Unable to open line comments popup: " .. tostring(err), vim.log.levels.WARN)
  end

  return true
end

function M.show_at_cursor(bufnr, opts)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local line = vim.api.nvim_win_get_cursor(0)[1]
  return M.show_at_line(bufnr, line, opts)
end

function M.attach_to_buffer(bufnr, ctx)
  ctx = ctx or {}
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local lc_config = (config.get() or {}).line_comments or {}
  M.clear_buffer(bufnr)

  if lc_config.enabled == false then
    return
  end

  local side = infer_side(bufnr, ctx)
  if not side then
    return
  end

  vim.b[bufnr].gh_pr_comment_side = side
  vim.b[bufnr].gh_pr_comment_popup_width = tonumber(ctx.max_popup_width) or tonumber(lc_config.max_popup_width) or 90
  vim.b[bufnr].gh_pr_comment_popup_height = tonumber(ctx.max_popup_height) or tonumber(lc_config.max_popup_height) or 18

  local keymap = safe_string(ctx.keymap, safe_string(lc_config.keymap, "K"))
  vim.keymap.set("n", keymap, function()
    M.show_at_cursor(bufnr)
  end, {
    buffer = bufnr,
    silent = true,
    nowait = true,
    desc = "GH PR: show line comments",
  })

  local index = type(ctx.index) == "table" and ctx.index or {}
  if vim.tbl_isempty(index) then
    vim.b[bufnr].gh_pr_line_comments = {}
    return
  end

  local file_path = safe_string(ctx.file_path, vim.b[bufnr].gh_pr_path)
  local alternatives = type(ctx.alternate_paths) == "table" and ctx.alternate_paths or {}
  local line_map = collect_line_map(index, side, file_path, alternatives)
  vim.b[bufnr].gh_pr_line_comments = line_map

  ensure_highlights()
  ensure_signs(type(ctx.signs) == "table" and ctx.signs or (lc_config.signs or {}))

  local style = safe_string(lc_config.indicator_style, "sign_and_virtual_text")
  local flags = indicator_style_flags(style)
  local vt_opts = virtual_text_options(lc_config)

  for line, entries in pairs(line_map) do
    local kind = marker_kind(entries)

    if flags.sign then
      pcall(vim.fn.sign_place, 0, sign_group, sign_names[kind], bufnr, {
        lnum = line,
        priority = 30,
      })
    end

    if flags.highlight then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, line - 1, 0, {
        line_hl_group = hl_groups[kind],
        hl_eol = true,
        priority = 80,
      })
    end

    if flags.virtual_text and vt_opts.enabled then
      local label = ""
      local virt_hl_group = virt_hl_groups[kind]

      label = build_multiline_progress_label(entries, vt_opts)
      if label ~= "" then
        virt_hl_group = "GhPrCommentVirtAuthors"
      elseif vt_opts.show_authors then
        label = build_authors_virtual_label(entries, vt_opts)
        if label ~= "" then
          virt_hl_group = "GhPrCommentVirtAuthors"
        end
      end

      if label == "" then
        label = build_count_virtual_label(entries, vt_opts)
      end

      pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, line - 1, 0, {
        virt_text = { { label, virt_hl_group } },
        virt_text_pos = vt_opts.position,
        priority = 60,
      })
    end
  end
end

return M
