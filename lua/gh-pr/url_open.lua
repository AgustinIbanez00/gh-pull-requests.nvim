local M = {}

local function normalize_url(url)
  local value = type(url) == "string" and vim.trim(url) or ""
  if value == "" then
    return nil, "Missing URL"
  end
  if not value:match("^https?://") then
    return nil, "Only http/https URLs are supported"
  end
  return value, nil
end

local function try_vim_ui_open(url)
  if not (vim.ui and type(vim.ui.open) == "function") then
    return false, "vim.ui.open is unavailable in this Neovim build"
  end

  local ok, open_result, open_err = pcall(vim.ui.open, url)
  if not ok then
    return false, tostring(open_result)
  end
  if open_result == false then
    return false, type(open_err) == "string" and open_err ~= "" and open_err or "vim.ui.open returned false"
  end
  if open_result == nil then
    return false, type(open_err) == "string" and open_err ~= "" and open_err or "vim.ui.open returned nil"
  end

  return true, nil
end

local function try_jobstart_command(command)
  local executable = type(command) == "table" and command[1] or nil
  if type(executable) ~= "string" or executable == "" then
    return false, "invalid command"
  end
  if vim.fn.executable(executable) ~= 1 then
    return false, executable .. " is unavailable"
  end

  local ok_job, jobid = pcall(vim.fn.jobstart, command, { detach = true })
  if ok_job and type(jobid) == "number" and jobid > 0 then
    return true, nil
  end
  return false, executable .. " failed to start"
end

local function try_system_open(url)
  local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local is_mac = vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1
  local commands = {}

  if is_windows then
    commands = {
      { "cmd.exe", "/c", "start", "", url },
      { "rundll32", "url.dll,FileProtocolHandler", url },
      { "explorer.exe", url },
    }
  elseif is_mac then
    commands = {
      { "open", url },
    }
  else
    commands = {
      { "xdg-open", url },
    }
  end

  local errors = {}
  for _, command in ipairs(commands) do
    local ok_open, open_err = try_jobstart_command(command)
    if ok_open then
      return true, nil
    end
    if type(open_err) == "string" and open_err ~= "" then
      errors[#errors + 1] = open_err
    end
  end

  if vim.tbl_isempty(errors) then
    return false, "Unable to open URL with system opener"
  end
  return false, table.concat(errors, " | ")
end

local function maybe_notify_error(err, opts)
  if type(opts) ~= "table" or opts.notify_error ~= true then
    return
  end
  local context = type(opts.context) == "string" and vim.trim(opts.context) or ""
  if context == "" then
    context = "Unable to open URL"
  end
  local message = context
  if type(err) == "string" and err ~= "" then
    message = message .. ": " .. err
  end
  vim.notify(message, vim.log.levels.ERROR)
end

function M.open(url, opts)
  opts = type(opts) == "table" and opts or {}

  local target, target_err = normalize_url(url)
  if not target then
    maybe_notify_error(target_err, opts)
    return false, target_err
  end

  local errors = {}
  local ok_ui, ui_err = try_vim_ui_open(target)
  if ok_ui then
    return true, nil
  end
  if type(ui_err) == "string" and ui_err ~= "" then
    errors[#errors + 1] = "vim.ui.open failed: " .. ui_err
  end

  local ok_system, system_err = try_system_open(target)
  if ok_system then
    return true, nil
  end
  if type(system_err) == "string" and system_err ~= "" then
    errors[#errors + 1] = "system opener failed: " .. system_err
  end

  local final_err
  if vim.tbl_isempty(errors) then
    final_err = "Unable to open URL"
  else
    final_err = table.concat(errors, " | ")
  end
  maybe_notify_error(final_err, opts)
  return false, final_err
end

return M
