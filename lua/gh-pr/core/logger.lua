-- Centralized file logger for gh-pr.
--
-- Writes timestamped, level-tagged lines to per-channel files under
-- `stdpath("state")/gh-pr/logs/`. Channels keep concerns separated so a
-- failure is easy to reproduce after the fact:
--   * lua       -> uncaught Lua errors (tracebacks of command/action handlers)
--   * codediff  -> codediff backend failures / diagnostics
--   * github    -> failed `gh` commands (and, at debug level, every call)
--   * general   -> generic errors/warnings also shown via vim.notify
--
-- This module is intentionally dependency-free: gh.lua (low level) and
-- notify.lua may require it before `setup` runs, so it ships with safe
-- internal defaults and is a no-op until enabled.

local M = {}

local CHANNELS = { "lua", "codediff", "github", "general" }

local LEVELS = {
  error = 1,
  warn = 2,
  info = 3,
  debug = 4,
}

local LEVEL_LABEL = {
  [1] = "ERROR",
  [2] = "WARN",
  [3] = "INFO",
  [4] = "DEBUG",
}

local defaults = {
  enabled = true,
  level = "warn",
  max_size_kb = 1024,
}

local state = {
  enabled = defaults.enabled,
  level = LEVELS[defaults.level],
  max_bytes = defaults.max_size_kb * 1024,
  dir = nil,
  dir_ready = false,
}

local function uv()
  return vim.uv or vim.loop
end

local function joinpath(...)
  if vim.fs and vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end

  local separator = package.config:sub(1, 1)
  return table.concat({ ... }, separator)
end

local function is_channel(channel)
  for _, name in ipairs(CHANNELS) do
    if name == channel then
      return true
    end
  end
  return false
end

function M.channels()
  return vim.deepcopy(CHANNELS)
end

function M.levels()
  return { "error", "warn", "info", "debug" }
end

function M.dir()
  if state.dir then
    return state.dir
  end

  state.dir = joinpath(vim.fn.stdpath("state"), "gh-pr", "logs")
  return state.dir
end

function M.path(channel)
  if not is_channel(channel) then
    channel = "general"
  end
  return joinpath(M.dir(), channel .. ".log")
end

local function ensure_dir()
  if state.dir_ready then
    return true
  end

  local ok = pcall(vim.fn.mkdir, M.dir(), "p")
  state.dir_ready = ok
  return ok
end

-- Rotate a single generation to `<channel>.log.old` when the file grows past
-- `max_bytes`. Best-effort; failures never block logging.
local function rotate_if_needed(path)
  if state.max_bytes <= 0 then
    return
  end

  local stat = uv().fs_stat(path)
  if not stat or (stat.size or 0) < state.max_bytes then
    return
  end

  pcall(os.remove, path .. ".old")
  pcall(os.rename, path, path .. ".old")
end

local function timestamp()
  return os.date("%Y-%m-%dT%H:%M:%S")
end

function M.setup(opts)
  opts = type(opts) == "table" and opts or {}

  if type(opts.enabled) == "boolean" then
    state.enabled = opts.enabled
  end

  if type(opts.level) == "string" and LEVELS[opts.level] then
    state.level = LEVELS[opts.level]
  end

  if type(opts.max_size_kb) == "number" and opts.max_size_kb > 0 then
    state.max_bytes = math.floor(opts.max_size_kb * 1024)
  end

  if type(opts.dir) == "string" and opts.dir ~= "" then
    state.dir = opts.dir
    state.dir_ready = false
  end
end

function M.get_level()
  return LEVEL_LABEL[state.level]:lower()
end

function M.set_level(level)
  if type(level) ~= "string" or not LEVELS[level] then
    return false, "Invalid log level: " .. tostring(level)
  end
  state.level = LEVELS[level]
  return true
end

-- Core entrypoint. `channel` and `level` are strings; `opts.traceback` is an
-- optional multi-line stack appended under the message (indented).
function M.log(channel, level, msg, opts)
  if not state.enabled then
    return
  end

  local level_value = LEVELS[level]
  if not level_value or level_value > state.level then
    return
  end

  if not is_channel(channel) then
    channel = "general"
  end

  if msg == nil or msg == "" then
    return
  end

  if not ensure_dir() then
    return
  end

  local path = M.path(channel)
  rotate_if_needed(path)

  local lines = { string.format("%s [%s] %s", timestamp(), LEVEL_LABEL[level_value], tostring(msg)) }

  opts = opts or {}
  if type(opts.traceback) == "string" and opts.traceback ~= "" then
    for _, tb_line in ipairs(vim.split(opts.traceback, "\n", { plain = true })) do
      lines[#lines + 1] = "    " .. tb_line
    end
  end

  pcall(function()
    local file = io.open(path, "a")
    if not file then
      return
    end
    file:write(table.concat(lines, "\n"), "\n")
    file:close()
  end)
end

function M.error(channel, msg, opts)
  M.log(channel, "error", msg, opts)
end

function M.warn(channel, msg, opts)
  M.log(channel, "warn", msg, opts)
end

function M.info(channel, msg, opts)
  M.log(channel, "info", msg, opts)
end

function M.debug(channel, msg, opts)
  M.log(channel, "debug", msg, opts)
end

-- Truncate one channel (or all when `channel` is nil/empty).
function M.clear(channel)
  local targets = {}
  if type(channel) == "string" and channel ~= "" then
    if not is_channel(channel) then
      return false, "Unknown log channel: " .. channel
    end
    targets[1] = channel
  else
    targets = CHANNELS
  end

  for _, name in ipairs(targets) do
    local path = M.path(name)
    pcall(function()
      local file = io.open(path, "w")
      if file then
        file:close()
      end
    end)
    pcall(os.remove, path .. ".old")
  end

  return true
end

-- Open a channel log (or the logs directory when `channel` is nil) in a
-- read-only buffer for quick inspection.
function M.open(channel)
  ensure_dir()

  if type(channel) == "string" and channel ~= "" then
    if not is_channel(channel) then
      return false, "Unknown log channel: " .. channel
    end

    local path = M.path(channel)
    if not uv().fs_stat(path) then
      pcall(function()
        local file = io.open(path, "a")
        if file then
          file:close()
        end
      end)
    end

    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.bo.modifiable = false
    vim.bo.readonly = true
    return true
  end

  vim.cmd("edit " .. vim.fn.fnameescape(M.dir()))
  return true
end

return M
