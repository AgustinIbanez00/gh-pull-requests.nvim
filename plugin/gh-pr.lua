if vim.g.loaded_gh_pr then
  return
end
vim.g.loaded_gh_pr = true

local function call(method, ...)
  local gh_pr = require("gh-pr")
  local handler = gh_pr[method]
  if type(handler) ~= "function" then
    vim.notify("Unknown gh-pr action: " .. tostring(method), vim.log.levels.ERROR)
    return
  end

  return handler(...)
end

local function command_no_args(method)
  return function()
    call(method)
  end
end

local command_specs = require("gh-pr.entrypoint.command_specs").build(call, command_no_args)
local plug_specs = require("gh-pr.entrypoint.plug_specs")
local autocmd_specs = require("gh-pr.entrypoint.autocmd_specs").build()

for _, spec in ipairs(command_specs) do
  vim.api.nvim_create_user_command(spec.name, spec.callback, spec.opts)
end

for _, spec in ipairs(plug_specs) do
  vim.keymap.set("n", spec.lhs, spec.rhs, { desc = spec.desc, silent = true })
end

for _, spec in ipairs(autocmd_specs) do
  vim.api.nvim_create_autocmd(spec.event, spec.opts)
end
