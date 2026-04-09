local highlights = require("gh-pr.highlights")
local registry = require("gh-pr.neotree.registry")

local DEFAULT_RENDERERS = {
  folder = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    { "container", width = "100%", content = { { "folder_viewed_badge", zindex = 10 }, { "name", zindex = 11 } } },
  },
  files = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  overview = {
    { "indent", with_expanders = false },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  directory = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    { "container", width = "100%", content = { { "folder_viewed_badge", zindex = 10 }, { "name", zindex = 11 } } },
  },
  commit = {
    { "indent", with_expanders = false },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  file = {
    { "indent", with_expanders = false },
    { "kind_icon" },
    {
      "container",
      width = "100%",
      content = {
        { "name", zindex = 10 },
        { "file_parent_path", zindex = 10 },
        { "file_review_badges", zindex = 20, align = "right" },
      },
    },
  },
  comment_file = {
    { "indent", with_expanders = true },
    { "kind_icon" },
    { "container", width = "100%", content = { { "name", zindex = 10 } } },
  },
  message = {
    { "indent", with_markers = false, with_expanders = false },
    { "kind_icon" },
    { "name", highlight = "NeoTreeMessage" },
  },
}

local function create(opts)
  opts = type(opts) == "table" and opts or {}
  local source_name = type(opts.source_name) == "string" and opts.source_name ~= "" and opts.source_name or "gh_pr_review"
  local display_name = type(opts.display_name) == "string" and opts.display_name ~= "" and opts.display_name
    or "GH PR Review"
  local source_module_name = type(opts.source_module_name) == "string" and opts.source_module_name ~= "" and opts.source_module_name
    or "gh-pr.neotree.review_source"

  local M = {
    name = source_name,
    display_name = display_name,
  }

  local function get_impl()
    local source = registry.get(source_name)
    if source then
      return source
    end

    source = require(source_module_name)
    registry.register(source_name, source)
    return source
  end

  function M.setup(source_config, _)
    highlights.ensure_baseline_links()

    local commands = require("gh-pr.neotree.review_commands")
    local components = require("gh-pr.neotree.components")

    source_config.commands = vim.tbl_deep_extend("force", source_config.commands or {}, commands)
    source_config.components = source_config.components or components
    source_config.renderers = vim.tbl_deep_extend("force", source_config.renderers or {}, DEFAULT_RENDERERS)

    source_config.window = source_config.window or {}
    source_config.window.mappings = source_config.window.mappings or {}

    local default_mappings = {
      ["<CR>"] = "gh_pr_review_open",
      ["R"] = "refresh",
      ["o"] = "open_overview",
      ["b"] = "open_pr_browser",
      ["T"] = "open_telescope_actions",
      ["d"] = "open_diff",
      ["O"] = "open_original",
      ["M"] = "open_modified",
      ["v"] = "toggle_viewed",
      ["a"] = "edit_assignees_multi",
      ["l"] = "edit_labels_multi",
      ["u"] = "edit_reviewers_multi",
      ["g"] = "comment_file_global",
      ["c"] = "comment_pr",
      ["r"] = "start_review",
      ["ra"] = "submit_pending_approve_review",
      ["rc"] = "submit_pending_comment_review",
      ["rr"] = "submit_pending_request_changes_review",
      ["rd"] = "discard_pending_review",
      ["zA"] = "expand_all_review_nodes",
      ["za"] = "collapse_all_review_nodes",
      ["zF"] = "expand_files_nodes",
      ["zf"] = "collapse_files_nodes",
      ["zt"] = "toggle_files_flat_mode",
      ["zV"] = "expand_viewed_file_paths",
      ["zv"] = "collapse_viewed_file_paths",
      ["/"] = "filter_files_by_path",
      ["z/"] = "clear_file_path_filter",
      ["zs"] = "select_file_status_filter",
      ["ze"] = "filter_files_by_extension",
      ["zn"] = "toggle_no_extension_filter",
      ["z."] = "toggle_dotfiles_filter",
      ["zu"] = "toggle_unviewed_only_filter",
      ["zw"] = "toggle_viewed_only_filter",
      ["zh"] = "toggle_hide_viewed_filter",
      ["zd"] = "toggle_hide_deleted_filter",
      ["zr"] = "reset_file_filters",
      ["zG"] = "expand_comments_global",
      ["zg"] = "collapse_comments_global",
      ["x"] = "toggle_review_tree",
      ["e"] = "toggle_auto_expand_width",
      ["q"] = "close_window",
      ["?"] = "show_help",
      ["<"] = "prev_source",
      [">"] = "next_source",
      ["y"] = "noop",
      ["<C-r>"] = "noop",
      ["t"] = "noop",
      ["w"] = "noop",
    }

    source_config.window.mappings = vim.tbl_deep_extend("force", source_config.window.mappings, default_mappings)
  end

  function M.navigate(state, path, path_to_reveal, callback, async)
    return get_impl().navigate(state, path, path_to_reveal, callback, async)
  end

  return M
end

local default_instance = create()
default_instance._create = create

return default_instance
