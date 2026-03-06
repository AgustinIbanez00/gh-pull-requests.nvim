local config = require("gh-pr.config")
local registry = require("gh-pr.neotree.registry")

local M = {
  name = "gh_pr_comments",
  display_name = "GH Comments",
}

local DEFAULT_RENDERERS = {
  folder = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  directory = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  file = {
    { "indent", with_expanders = false },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  message = {
    { "indent", with_markers = false, with_expanders = false },
    { "kind_icon" },
    { "name", highlight = "NeoTreeMessage" },
  },
}

local function get_impl()
  local source = registry.get("gh_pr_comments")
  if source then
    return source
  end

  source = require("gh-pr.neotree.comments_source")
  registry.register("gh_pr_comments", source)
  return source
end

function M.setup(source_config, _)
  local commands = require("gh-pr.neotree.comments_commands")
  local components = require("gh-pr.neotree.components")
  local options = (((config.get() or {}).line_comments or {}).comments_tree or {}).preview or {}
  local preview_keymap = type(options.keymap) == "string" and options.keymap ~= "" and options.keymap or "p"

  source_config.commands = vim.tbl_deep_extend("force", source_config.commands or {}, commands)
  source_config.components = source_config.components or components
  source_config.renderers = vim.tbl_deep_extend("force", source_config.renderers or {}, DEFAULT_RENDERERS)

  source_config.window = source_config.window or {}
  source_config.window.mappings = source_config.window.mappings or {}

  local default_mappings = {
    ["<space>"] = "toggle_node",
    ["<CR>"] = "gh_pr_comments_open",
    ["o"] = "open_comment",
    [preview_keymap] = "preview_comment",
    ["R"] = "refresh",
    ["q"] = "close_window",
    ["?"] = "show_help",
    ["<"] = "prev_source",
    [">"] = "next_source",
    ["A"] = "noop",
    ["x"] = "noop",
    ["y"] = "noop",
    ["<C-r>"] = "noop",
    ["S"] = "noop",
    ["s"] = "noop",
    ["t"] = "noop",
    ["w"] = "noop",
    ["e"] = "noop",
  }

  source_config.window.mappings = vim.tbl_deep_extend("force", source_config.window.mappings, default_mappings)
end

function M.navigate(state, path, path_to_reveal, callback, async)
  return get_impl().navigate(state, path, path_to_reveal, callback, async)
end

return M
