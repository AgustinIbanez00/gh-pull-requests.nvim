local config = require("gh-pr.config")
local diff_shortcuts = require("gh-pr.diff_shortcuts")
local registry = require("gh-pr.neotree.registry")

local M = {
  name = "gh_pr_diff_review",
  display_name = "GH Diff Review",
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
  local source = registry.get("gh_pr_diff_review")
  if source then return source end
  source = require("gh-pr.neotree.diff_review_source")
  registry.register("gh_pr_diff_review", source)
  return source
end

function M.setup(source_config, _)
  local commands = require("gh-pr.neotree.diff_review_commands")
  local components = require("gh-pr.neotree.components")
  local preview_options = (((config.get() or {}).line_comments or {}).comments_tree or {}).preview or {}
  local configured_shortcuts = ((config.get() or {}).diff_view or {}).shortcuts or {}
  configured_shortcuts = diff_shortcuts.resolve(configured_shortcuts)
  configured_shortcuts = diff_shortcuts.expand_localleader(configured_shortcuts)

  local preview_keymap = type(preview_options.keymap) == "string" and preview_options.keymap ~= "" and preview_options.keymap or "p"
  local toggle_keymap = type(configured_shortcuts.toggle_review_panel) == "string" and configured_shortcuts.toggle_review_panel or ""

  source_config.commands = vim.tbl_deep_extend("force", source_config.commands or {}, commands)
  source_config.components = source_config.components or components
  source_config.renderers = vim.tbl_deep_extend("force", source_config.renderers or {}, DEFAULT_RENDERERS)

  source_config.window = source_config.window or {}
  source_config.window.mappings = source_config.window.mappings or {}

  local default_mappings = {
    ["<space>"] = "toggle_node",
    ["<CR>"] = "gh_pr_diff_review_open",
    ["o"] = "open_comment",
    [preview_keymap] = "preview_comment",
    ["R"] = "refresh",
    ["q"] = "close_window",
    ["?"] = "show_help",
    ["<"] = "noop",
    [">"] = "noop",
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

  if toggle_keymap ~= "" then
    default_mappings[toggle_keymap] = "close_window"
  end

  source_config.window.mappings = vim.tbl_deep_extend("force", source_config.window.mappings, default_mappings)
end

function M.navigate(state, path, path_to_reveal, callback, async)
  return get_impl().navigate(state, path, path_to_reveal, callback, async)
end

return M
