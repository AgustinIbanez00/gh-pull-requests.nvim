local M = {}

local function sanitize_key(key, fallback)
  if type(key) ~= "string" or key == "" then
    return fallback
  end
  return key
end

function M.sanitize(input)
  local source = type(input) == "table" and input or {}
  return {
    cycle_next = sanitize_key(source.cycle_next, "<Tab>"),
    cycle_prev = sanitize_key(source.cycle_prev, "<S-Tab>"),
    focus_summary = sanitize_key(source.focus_summary, "g1"),
    focus_activity = sanitize_key(source.focus_activity, "g2"),
    focus_meta = sanitize_key(source.focus_meta, "g3"),
    help = sanitize_key(source.help, "?"),
    focus_left = sanitize_key(source.focus_left, "<C-h>"),
    focus_down = sanitize_key(source.focus_down, "<C-j>"),
    focus_up = sanitize_key(source.focus_up, "<C-k>"),
    focus_right = sanitize_key(source.focus_right, "<C-l>"),
  }
end

local function map(bufnr, lhs, rhs, desc)
  if type(lhs) ~= "string" or lhs == "" then
    return
  end
  vim.keymap.set("n", lhs, rhs, {
    buffer = bufnr,
    silent = true,
    nowait = false,
    desc = desc,
  })
end

function M.attach(session, role, handlers)
  local bufnr = session.buffers[role]
  if type(bufnr) ~= "number" or bufnr < 1 then
    return
  end

  local function run_callback(name)
    if type(handlers.callback) == "function" then
      handlers.callback(name)
    end
  end

  local function execute(variant)
    if type(handlers.execute) == "function" then
      handlers.execute(role, variant)
    end
  end

  local function focus(target)
    if type(handlers.focus) == "function" then
      handlers.focus(target)
    end
  end

  local function cycle(step)
    if type(handlers.cycle) == "function" then
      handlers.cycle(step)
    end
  end

  map(bufnr, "a", function()
    run_callback("approve")
  end, "GH PR Overview: approve")
  map(bufnr, "d", function()
    run_callback("request_changes")
  end, "GH PR Overview: request changes")
  map(bufnr, "c", function()
    run_callback("comment")
  end, "GH PR Overview: comment")
  map(bufnr, "m", function()
    run_callback("merge")
  end, "GH PR Overview: merge")
  map(bufnr, "k", function()
    run_callback("checkout")
  end, "GH PR Overview: checkout")
  map(bufnr, "b", function()
    run_callback("open_url")
  end, "GH PR Overview: open PR in browser")
  map(bufnr, "C", function()
    run_callback("open_comments_tree")
  end, "GH PR Overview: open comments tree")
  map(bufnr, "R", function()
    if type(handlers.refresh) == "function" then
      handlers.refresh()
    end
  end, "GH PR Overview: refresh")
  map(bufnr, ",x", function()
    run_callback("toggle_review_tree")
  end, "GH PR Overview: toggle review tree")
  map(bufnr, "q", function()
    if type(handlers.close) == "function" then
      handlers.close()
    end
  end, "GH PR Overview: close")
  map(bufnr, session.keymaps.help, function()
    if type(handlers.help) == "function" then
      handlers.help(role)
    end
  end, "GH PR Overview: help")

  map(bufnr, "<CR>", function()
    execute("default")
  end, "GH PR Overview: open selection")
  map(bufnr, "D", function()
    execute("default")
  end, "GH PR Overview: open selection")
  map(bufnr, "O", function()
    execute("original")
  end, "GH PR Overview: open original file")
  map(bufnr, "M", function()
    execute("modified")
  end, "GH PR Overview: open modified file")
  map(bufnr, "gr", function()
    if type(handlers.more) == "function" then
      handlers.more(role)
    end
  end, "GH PR Overview: load more")

  map(bufnr, session.keymaps.cycle_next, function()
    cycle(1)
  end, "GH PR Overview: next pane")
  map(bufnr, session.keymaps.cycle_prev, function()
    cycle(-1)
  end, "GH PR Overview: previous pane")

  map(bufnr, session.keymaps.focus_summary, function()
    focus("summary")
  end, "GH PR Overview: focus summary")
  map(bufnr, session.keymaps.focus_activity, function()
    focus("activity")
  end, "GH PR Overview: focus activity")
  map(bufnr, session.keymaps.focus_meta, function()
    focus("meta")
  end, "GH PR Overview: focus collaboration")

  map(bufnr, session.keymaps.focus_left, function()
    focus("summary")
  end, "GH PR Overview: focus summary")
  map(bufnr, session.keymaps.focus_down, function()
    focus("activity")
  end, "GH PR Overview: focus activity")
  map(bufnr, session.keymaps.focus_up, function()
    focus("summary")
  end, "GH PR Overview: focus summary")
  map(bufnr, session.keymaps.focus_right, function()
    focus("meta")
  end, "GH PR Overview: focus collaboration")

  map(bufnr, "<C-w>w", function()
    cycle(1)
  end, "GH PR Overview: next pane")
  map(bufnr, "<C-w>W", function()
    cycle(-1)
  end, "GH PR Overview: previous pane")
  map(bufnr, "<C-w>h", function()
    focus("summary")
  end, "GH PR Overview: focus summary")
  map(bufnr, "<C-w>j", function()
    focus("activity")
  end, "GH PR Overview: focus activity")
  map(bufnr, "<C-w>k", function()
    focus("summary")
  end, "GH PR Overview: focus summary")
  map(bufnr, "<C-w>l", function()
    focus("meta")
  end, "GH PR Overview: focus collaboration")
end

return M

