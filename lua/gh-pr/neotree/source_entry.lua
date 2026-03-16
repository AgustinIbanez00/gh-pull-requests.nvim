local highlights = require("gh-pr.highlights")
local registry = require("gh-pr.neotree.registry")

local M = {
  name = "gh_pr",
  display_name = "GH PR",
}

local DEFAULT_RENDERERS = {
  folder = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  query = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  pr = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    {
      "container",
      width = "100%",
      content = {
        { "pr_title", zindex = 10 },
        { "pr_meta_badges", zindex = 20, align = "right" },
      },
    },
  },
  files = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  directory = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  overview = {
    { "indent", with_expanders = false },
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
  local source = registry.get("gh_pr")
  if source then
    return source
  end

  source = require("gh-pr.neotree.source")
  registry.register("gh_pr", source)
  return source
end

function M.setup(source_config, _)
  highlights.ensure_baseline_links()

  local commands = require("gh-pr.neotree.commands")
  local components = require("gh-pr.neotree.components")
  source_config.commands = vim.tbl_deep_extend("force", source_config.commands or {}, commands)
  source_config.components = source_config.components or components
  source_config.renderers = vim.tbl_deep_extend("force", source_config.renderers or {}, DEFAULT_RENDERERS)

  source_config.window = source_config.window or {}
  source_config.window.mappings = source_config.window.mappings or {}

  local default_mappings = {
    ["<CR>"] = "gh_pr_open",
    ["R"] = "refresh",
    ["b"] = "open_pr_browser",
    ["r"] = "start_review",
    ["ra"] = "approve_review",
    ["rc"] = "comment_review",
    ["rr"] = "request_changes_review",
    ["rd"] = "discard_pending_review",
    ["m"] = "merge_pr",
    ["k"] = "checkout_pr",
    ["q"] = "close_window",
    ["?"] = "show_help",
    ["<"] = "prev_source",
    [">"] = "next_source",
  }

  source_config.window.mappings = vim.tbl_deep_extend("force", source_config.window.mappings, default_mappings)
end

function M.navigate(state, path, path_to_reveal, callback, async)
  return get_impl().navigate(state, path, path_to_reveal, callback, async)
end

return M
