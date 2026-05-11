local M = {}
local reviewer_model = require("gh-pr.core.reviewers")

function M.build_nodes(pr, details)
  local reviewers = reviewer_model.build(details)
  local nodes = {}
  for _, item in ipairs(reviewers) do
    nodes[#nodes + 1] = {
      id = string.format("ghpr-review:%d:reviewer:%s", pr.number, item.id),
      name = string.format("%s [%s]", item.display_name, item.state),
      type = "file",
      extra = {
        kind = "reviewer",
        reviewer_state = item.state,
        reviewer = item,
        pr = pr,
        details = details,
      },
    }
  end

  table.sort(nodes, function(left, right)
    return left.name < right.name
  end)

  if vim.tbl_isempty(nodes) then
    return {
      {
        id = string.format("ghpr-review:%d:reviewers-empty", pr.number),
        name = "No reviewers found",
        type = "message",
        extra = {
          kind = "message",
          pr = pr,
          details = details,
        },
      },
    }
  end

  return nodes
end

function M.count_states(nodes)
  local reviewers = {}
  for _, node in ipairs(type(nodes) == "table" and nodes or {}) do
    local extra = type(node) == "table" and type(node.extra) == "table" and node.extra or nil
    if extra and extra.kind == "reviewer" then
      reviewers[#reviewers + 1] = extra.reviewer or { state = extra.reviewer_state }
    end
  end
  return reviewer_model.count_states(reviewers)
end

return M
