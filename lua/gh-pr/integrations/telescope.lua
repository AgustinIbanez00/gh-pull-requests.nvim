local M = {}

local function notify_error(opts, message)
  local on_error = type(opts) == "table" and opts.on_error or nil
  if type(on_error) == "function" then
    on_error(message)
    return
  end

  vim.notify(message, vim.log.levels.ERROR)
end

local function resolve_module(opts)
  local ok, telescope = pcall(require, "gh-pr.telescope")
  if ok then
    return telescope
  end

  local message = type(opts) == "table" and opts.load_error or nil
  if type(message) ~= "string" or message == "" then
    message = "Unable to load Telescope fallback"
  end

  notify_error(opts, message)
  return nil
end

function M.call(handler_name, handler_opts, opts)
  local telescope = resolve_module(opts)
  if not telescope then
    return false
  end

  local handler = telescope[handler_name]
  if type(handler) ~= "function" then
    local message = type(opts) == "table" and opts.missing_handler_error or nil
    if type(message) ~= "string" or message == "" then
      message = "Telescope fallback action is not available: " .. tostring(handler_name)
    end
    notify_error(opts, message)
    return false
  end

  handler(handler_opts)
  return true
end

function M.open_pull_requests(opts)
  return M.call("pull_requests", nil, opts)
end

function M.open_context_actions(handler_opts, opts)
  return M.call("open_context_actions", handler_opts, opts)
end

function M.open_review_actions(handler_opts, opts)
  return M.call("open_review_actions", handler_opts, opts)
end

return M
