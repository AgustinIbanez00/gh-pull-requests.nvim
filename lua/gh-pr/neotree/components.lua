local highlights = require("neo-tree.ui.highlights")
local common = require("neo-tree.sources.common.components")
local runtime_state = require("gh-pr.state")

local M = {}

local function icon_for_node(node)
  if node.type == "directory" or node.type == "folder" or node.type == "query" or node.type == "files" then
    if node:is_expanded() then
      return { text = " ", highlight = highlights.DIRECTORY_ICON }
    end
    return { text = " ", highlight = highlights.DIRECTORY_ICON }
  end

  if node.type == "pr" then
    return { text = " ", highlight = highlights.DIRECTORY_ICON }
  end

  if node.type == "overview" then
    return { text = "󰈙 ", highlight = highlights.FILE_ICON }
  end

  if node.type == "message" then
    return { text = "󰍡 ", highlight = highlights.MESSAGE }
  end

  if node.type == "file" then
    local ok, devicons = pcall(require, "nvim-web-devicons")
    if ok then
      local icon, icon_hl = devicons.get_icon(node.name, nil, { default = true })
      if icon then
        return { text = icon .. " ", highlight = icon_hl or highlights.FILE_ICON }
      end
    end
    return { text = "󰈙 ", highlight = highlights.FILE_ICON }
  end

  return { text = "󰉋 ", highlight = highlights.DIRECTORY_ICON }
end

M.kind_icon = function(_, node, _)
  return icon_for_node(node)
end

M.name = function(config, node, _)
  local text = node.name or ""
  local hl = config.highlight or highlights.FILE_NAME

  if node.type == "message" then
    hl = highlights.MESSAGE
  elseif node.type == "directory" or node.type == "folder" or node.type == "query" or node.type == "pr" or node.type == "files" then
    hl = highlights.DIRECTORY_NAME
  end

  if node.extra and node.extra.kind == "file" and node.extra.repo and node.extra.pr and node.path then
    local viewed = runtime_state.is_viewed(node.extra.repo, node.extra.pr.number, node.path)
    if viewed then
      text = "✓ " .. text
      hl = highlights.DIM_TEXT
    end
  end

  return {
    text = text,
    highlight = hl,
  }
end

return vim.tbl_deep_extend("force", common, M)
