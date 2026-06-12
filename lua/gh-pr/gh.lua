local M = {}
local unpack_fn = table.unpack or unpack

-- Lazy, dependency-free access to the file logger. gh.lua is low level and may
-- run before setup, so failures to load the logger are ignored.
local function logger()
  local ok, mod = pcall(require, "gh-pr.core.logger")
  if ok then
    return mod
  end
  return nil
end

local function log_github_error(message)
  local log = logger()
  if log then
    log.error("github", message)
  end
end

local function log_github_warn(message)
  local log = logger()
  if log then
    log.warn("github", message)
  end
end

local function log_github_debug(message)
  local log = logger()
  if log then
    log.debug("github", message)
  end
end

local function elapsed_ms(start_ns)
  local clock = vim.uv or vim.loop
  if not start_ns or not clock or not clock.hrtime then
    return nil
  end
  return (clock.hrtime() - start_ns) / 1e6
end

local function run_with_vim_system(args, opts)
  local object = vim.system(args, {
    text = true,
    cwd = opts.cwd,
    stdin = opts.stdin,
  }):wait(opts.timeout_ms or 30000)

  return object.code or 1, object.stdout or "", object.stderr or ""
end

local function run_with_fn_system(args, opts)
  local stdout
  if opts.stdin then
    stdout = vim.fn.system(args, opts.stdin)
  else
    stdout = vim.fn.system(args)
  end

  local stderr = ""
  local code = vim.v.shell_error or 0
  return code, stdout or "", stderr
end

local function run_raw(args, opts)
  opts = opts or {}

  if vim.system then
    return run_with_vim_system(args, opts)
  end

  return run_with_fn_system(args, opts)
end

local function format_error(args, stderr, stdout)
  local command = table.concat(args, " ")
  local message = stderr ~= "" and stderr or stdout
  message = vim.trim(message)

  if message == "" then
    message = "unknown error"
  end

  local result = string.format("%s failed: %s", command, message)
  log_github_error(result)
  return result
end

local function schedule_callback(callback, ...)
  if type(callback) ~= "function" then
    return
  end

  local args = { ... }
  vim.schedule(function()
    callback(unpack_fn(args))
  end)
end

local function run_with_jobstart(command, opts, callback)
  local stdout_chunks = {}
  local stderr_chunks = {}
  local completed = false

  local function append_chunks(target, data)
    if type(data) ~= "table" then
      return
    end

    for _, chunk in ipairs(data) do
      if type(chunk) == "string" and chunk ~= "" then
        target[#target + 1] = chunk
      end
    end
  end

  local function finish(code)
    if completed then
      return
    end
    completed = true

    local stdout = table.concat(stdout_chunks, "\n")
    local stderr = table.concat(stderr_chunks, "\n")
    if code ~= 0 then
      schedule_callback(callback, nil, format_error(command, stderr, stdout))
      return
    end

    log_github_debug(table.concat(command, " ") .. " -> ok")
    schedule_callback(callback, stdout, nil)
  end

  local job_opts = {
    cwd = opts.cwd,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      append_chunks(stdout_chunks, data)
    end,
    on_stderr = function(_, data)
      append_chunks(stderr_chunks, data)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        finish(code or 1)
      end)
    end,
  }

  local job_id = vim.fn.jobstart(command, job_opts)
  if job_id <= 0 then
    local message = "Failed to start command: " .. table.concat(command, " ")
    log_github_error(message)
    schedule_callback(callback, nil, message)
    return
  end

  if opts.stdin ~= nil then
    vim.fn.chansend(job_id, opts.stdin)
    vim.fn.chanclose(job_id, "stdin")
  end
end

function M.run_command(args, opts)
  opts = opts or {}
  local command = vim.deepcopy(args)
  local clock = vim.uv or vim.loop
  local start_ns = clock and clock.hrtime and clock.hrtime() or nil
  local code, stdout, stderr = run_raw(command, opts)

  if code ~= 0 then
    return nil, format_error(command, stderr, stdout)
  end

  local ms = elapsed_ms(start_ns)
  log_github_debug(string.format("%s -> ok%s", table.concat(command, " "), ms and string.format(" (%.0fms)", ms) or ""))
  return stdout, nil
end

function M.run_command_async(args, opts, callback)
  opts = opts or {}
  callback = callback or function() end
  local command = vim.deepcopy(args)

  if vim.system then
    local clock = vim.uv or vim.loop
    local start_ns = clock and clock.hrtime and clock.hrtime() or nil
    local ok, async_err = pcall(function()
      vim.system(command, {
        text = true,
        cwd = opts.cwd,
        stdin = opts.stdin,
      }, function(object)
        local code = object.code or 1
        local stdout = object.stdout or ""
        local stderr = object.stderr or ""
        if code ~= 0 then
          schedule_callback(callback, nil, format_error(command, stderr, stdout))
          return
        end
        local ms = elapsed_ms(start_ns)
        log_github_debug(string.format("%s -> ok%s", table.concat(command, " "), ms and string.format(" (%.0fms)", ms) or ""))
        schedule_callback(callback, stdout, nil)
      end)
    end)

    if not ok then
      log_github_error(tostring(async_err))
      schedule_callback(callback, nil, tostring(async_err))
    end
    return
  end

  run_with_jobstart(command, opts, callback)
end

function M.run(args, opts)
  local command = vim.deepcopy(args)
  if command[1] ~= "gh" then
    table.insert(command, 1, "gh")
  end

  return M.run_command(command, opts)
end

function M.run_async(args, opts, callback)
  local command = vim.deepcopy(args)
  if command[1] ~= "gh" then
    table.insert(command, 1, "gh")
  end

  return M.run_command_async(command, opts, callback)
end

function M.run_json(args, opts)
  local output, err = M.run(args, opts)
  if not output then
    return nil, err
  end

  local ok, decoded = pcall(vim.json.decode, output)
  if not ok then
    log_github_warn("Failed to decode gh output as JSON: " .. table.concat(args, " "))
    return nil, "Failed to decode gh output as JSON"
  end

  return decoded, nil
end

function M.run_json_async(args, opts, callback)
  callback = callback or function() end
  M.run_async(args, opts, function(output, err)
    if not output then
      callback(nil, err)
      return
    end

    local ok, decoded = pcall(vim.json.decode, output)
    if not ok then
      log_github_warn("Failed to decode gh output as JSON: " .. table.concat(args, " "))
      callback(nil, "Failed to decode gh output as JSON")
      return
    end

    callback(decoded, nil)
  end)
end

function M.run_json_command(args, opts)
  local output, err = M.run_command(args, opts)
  if not output then
    return nil, err
  end

  local ok, decoded = pcall(vim.json.decode, output)
  if not ok then
    log_github_warn("Failed to decode command output as JSON: " .. table.concat(args, " "))
    return nil, "Failed to decode command output as JSON"
  end

  return decoded, nil
end

function M.run_json_command_async(args, opts, callback)
  callback = callback or function() end
  M.run_command_async(args, opts, function(output, err)
    if not output then
      callback(nil, err)
      return
    end

    local ok, decoded = pcall(vim.json.decode, output)
    if not ok then
      log_github_warn("Failed to decode command output as JSON: " .. table.concat(args, " "))
      callback(nil, "Failed to decode command output as JSON")
      return
    end

    callback(decoded, nil)
  end)
end

return M
