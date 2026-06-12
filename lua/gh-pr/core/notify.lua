local M = {}

local LOG_LEVEL = {
  [vim.log.levels.ERROR] = "error",
  [vim.log.levels.WARN] = "warn",
  [vim.log.levels.INFO] = "info",
}

local function mirror_to_log(level, message)
  local ok, logger = pcall(require, "gh-pr.core.logger")
  if ok then
    logger.log("general", LOG_LEVEL[level] or "info", message)
  end
end

local function dispatch(level, message)
  if message == nil or message == "" then
    return
  end

  mirror_to_log(level, message)
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
