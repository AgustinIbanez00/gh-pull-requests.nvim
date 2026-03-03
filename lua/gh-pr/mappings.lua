local M = {}

local applied_global_mappings = {}
local global_mapping_specs = {
  { key = "open", plug = "<Plug>(gh-pr-open)", desc = "Open PR tree" },
  { key = "list", plug = "<Plug>(gh-pr-list)", desc = "List PRs (Telescope)" },
  { key = "comments", plug = "<Plug>(gh-pr-comments)", desc = "Open PR comments tree" },
  { key = "refresh", plug = "<Plug>(gh-pr-refresh)", desc = "Refresh PR data" },
  { key = "overview", plug = "<Plug>(gh-pr-overview)", desc = "Open PR overview" },
  { key = "checkout", plug = "<Plug>(gh-pr-checkout)", desc = "Checkout PR" },
  { key = "open_diff", plug = "<Plug>(gh-pr-open-diff)", desc = "Open PR file diff" },
  { key = "review_tree", plug = "<Plug>(gh-pr-review-tree)", desc = "Toggle PR Review source" },
  { key = "toggle_reviewed", plug = "<Plug>(gh-pr-toggle-reviewed)", desc = "Toggle viewed" },
  { key = "next_change", plug = "<Plug>(gh-pr-next-change)", desc = "Next diff change" },
  { key = "prev_change", plug = "<Plug>(gh-pr-prev-change)", desc = "Previous diff change" },
}

local function get_normal_map_rhs(lhs)
  local mapping = vim.fn.maparg(lhs, "n", false, true)
  if type(mapping) ~= "table" then
    return nil
  end
  local rhs = mapping.rhs
  if type(rhs) ~= "string" or rhs == "" then
    return nil
  end
  return rhs
end

function M.clear_global_default_mappings()
  for lhs, metadata in pairs(applied_global_mappings) do
    if get_normal_map_rhs(lhs) == metadata.plug then
      pcall(vim.keymap.del, "n", lhs)
    end
  end
  applied_global_mappings = {}
end

function M.apply_global_default_mappings(options)
  M.clear_global_default_mappings()

  local mappings_config = type(options) == "table" and type(options.mappings) == "table" and options.mappings or {}
  local global_config = type(mappings_config.global) == "table" and mappings_config.global or {}
  if global_config.enabled ~= true then
    return
  end

  local configured_keys = type(global_config.keys) == "table" and global_config.keys or {}
  for _, spec in ipairs(global_mapping_specs) do
    local lhs = configured_keys[spec.key]
    if type(lhs) == "string" and lhs ~= "" then
      local existing_rhs = get_normal_map_rhs(lhs)
      -- Do not override existing user mappings when opt-in defaults are enabled.
      if not existing_rhs or existing_rhs == spec.plug then
        vim.keymap.set("n", lhs, spec.plug, {
          desc = spec.desc,
          remap = true,
          silent = true,
        })
        applied_global_mappings[lhs] = { plug = spec.plug }
      end
    end
  end
end

return M
