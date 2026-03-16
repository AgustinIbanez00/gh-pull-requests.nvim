local M = {}

local function dispatch(level, message)
  if message == nil or message == "" then
    return
  end

  vim.notify(message, level)
end

function M.error(message)
  dispatch(vim.log.levels.ERROR, message)
end

function M.info(message)
  dispatch(vim.log.levels.INFO, message)
end

function M.warn(message)
  dispatch(vim.log.levels.WARN, message)
end

return M
