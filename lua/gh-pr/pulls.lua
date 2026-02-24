local M = {}

local actions = require("gh-pr.actions")
local config = require("gh-pr.config")
local pr_service = require("gh-pr.pr_service")

function M.fetch()
  local combined = {}
  local seen = {}

  for _, query in ipairs(config.get_queries()) do
    local prs = pr_service.list_for_query(query.query)
    if prs then
      for _, pr in ipairs(prs) do
        if not seen[pr.number] then
          seen[pr.number] = true
          table.insert(combined, pr)
        end
      end
    end
  end

  return combined
end

function M.fetch_details(number)
  local details, err = pr_service.fetch_details(number)
  if not details then
    vim.notify(err, vim.log.levels.ERROR)
    return {}
  end

  return details
end

function M.open_file_diff(details, file)
  if details then
    actions.set_active_pr(details, details)
  end
  if file then
    actions.set_active_file(file)
  end
  actions.open_diff(file)
end

function M.toggle_reviewed()
  actions.toggle_viewed()
end

function M.next_change()
  actions.next_change()
end

function M.prev_change()
  actions.prev_change()
end

return M
