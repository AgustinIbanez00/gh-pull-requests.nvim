local M = {}

local pulls = require('gh-pr.pulls')

local function make_display(pr)
  local reviewers = pulls.reviewer_summary(pr)
  local decision = pr.reviewDecision or 'UNKNOWN'
  return string.format('#%d %s [%s] %s', pr.number, pr.title, decision, reviewers)
end

function M.pull_requests()
  local ok, pickers = pcall(require, 'telescope.pickers')
  if not ok then
    vim.notify('telescope.nvim is required', vim.log.levels.ERROR)
    return
  end
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local pulls_data = pulls.fetch()
  pickers.new({}, {
    prompt_title = 'My Pull Requests',
    finder = finders.new_table {
      results = pulls_data,
      entry_maker = function(pr)
        return {
          value = pr,
          display = make_display(pr),
          ordinal = pr.title,
        }
      end,
    },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr, map)
      local actions = require('telescope.actions')
      local action_state = require('telescope.actions.state')
      local function select()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if selection and selection.value then
          vim.notify('accediste a PR#' .. selection.value.number)
        end
      end
      map('i', '<CR>', select)
      map('n', '<CR>', select)
      return true
    end,
  }):find()
end

return M

