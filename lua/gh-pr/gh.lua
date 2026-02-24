local M = {}
local unpack_fn = table.unpack or unpack

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

  return string.format("%s failed: %s", command, message)
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

function M.run_command(args, opts)
  opts = opts or {}
  local command = vim.deepcopy(args)
  local code, stdout, stderr = run_raw(command, opts)

  if code ~= 0 then
    return nil, format_error(command, stderr, stdout)
  end

  return stdout, nil
end

function M.run_command_async(args, opts, callback)
  opts = opts or {}
  callback = callback or function() end
  local command = vim.deepcopy(args)

  if vim.system then
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
        schedule_callback(callback, stdout, nil)
      end)
    end)

    if not ok then
      schedule_callback(callback, nil, tostring(async_err))
    end
    return
  end

  vim.schedule(function()
    local output, err = M.run_command(command, opts)
    callback(output, err)
  end)
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
      callback(nil, "Failed to decode command output as JSON")
      return
    end

    callback(decoded, nil)
  end)
end

return M
