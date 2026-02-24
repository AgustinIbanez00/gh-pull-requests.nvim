local M = {}

function M.open(model, opts)
  local snacks_ok = pcall(require, "snacks")
  if not snacks_ok then
    vim.notify("gh-pr overview requires snacks.nvim", vim.log.levels.ERROR)
    return
  end

  local renderer_ok, renderer = pcall(require, "gh-pr.overview_snacks")
  if not renderer_ok then
    vim.notify("Unable to load interactive overview renderer", vim.log.levels.ERROR)
    return
  end

  renderer.open(model, opts or {})
end

return M
