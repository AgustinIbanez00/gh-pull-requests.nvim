local M = {}

---Setup gh-pr plugin.
---Currently a placeholder for future configuration.
function M.setup()
  -- TODO: initialize plugin components
end

---Open a picker displaying the user's open pull requests.
function M.open_pull_requests()
  require('gh-pr.telescope').pull_requests()
end

return M

