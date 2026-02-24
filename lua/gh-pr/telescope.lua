local M = {}

local actions = require("gh-pr.actions")
local pr_service = require("gh-pr.pr_service")

local function telescope_modules()
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    vim.notify("telescope.nvim is required for :GhPrList", vim.log.levels.ERROR)
    return nil
  end

  return {
    pickers = pickers,
    finders = require("telescope.finders"),
    conf = require("telescope.config").values,
    actions = require("telescope.actions"),
    action_state = require("telescope.actions.state"),
  }
end

local function select_file_picker(modules, details)
  local files = details.files or {}
  if vim.tbl_isempty(files) then
    vim.notify("No files in pull request", vim.log.levels.WARN)
    return
  end

  modules.pickers
    .new({}, {
      prompt_title = string.format("PR #%d Files", details.number),
      finder = modules.finders.new_table({
        results = files,
        entry_maker = function(file)
          local path = file.path or file.filename
          local status = file.status or "modified"
          return {
            value = file,
            display = string.format("[%s] %s", status, path),
            ordinal = path,
          }
        end,
      }),
      sorter = modules.conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        local function open_file()
          local selection = modules.action_state.get_selected_entry()
          modules.actions.close(prompt_bufnr)
          if selection and selection.value then
            actions.open_diff(selection.value)
          end
        end

        map("i", "<CR>", open_file)
        map("n", "<CR>", open_file)
        return true
      end,
    })
    :find()
end

local function select_pr_action_picker(modules, pr)
  local details, err = pr_service.fetch_details(pr.number)
  if not details then
    vim.notify(err, vim.log.levels.ERROR)
    return
  end

  actions.set_active_pr(details, details)

  local pr_actions = {
    { id = "overview", label = "Open overview" },
    { id = "files", label = "Browse files" },
    { id = "checkout", label = "Checkout branch" },
  }

  modules.pickers
    .new({}, {
      prompt_title = string.format("PR #%d Actions", pr.number),
      finder = modules.finders.new_table({
        results = pr_actions,
        entry_maker = function(item)
          return {
            value = item,
            display = item.label,
            ordinal = item.label,
          }
        end,
      }),
      sorter = modules.conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        local function run_action()
          local selection = modules.action_state.get_selected_entry()
          modules.actions.close(prompt_bufnr)
          if not selection or not selection.value then
            return
          end

          if selection.value.id == "overview" then
            actions.open_overview(pr.number)
          elseif selection.value.id == "files" then
            select_file_picker(modules, details)
          elseif selection.value.id == "checkout" then
            actions.checkout(pr.number)
          end
        end

        map("i", "<CR>", run_action)
        map("n", "<CR>", run_action)
        return true
      end,
    })
    :find()
end

local function select_pr_picker(modules, query_result)
  modules.pickers
    .new({}, {
      prompt_title = query_result.query.label,
      finder = modules.finders.new_table({
        results = query_result.prs,
        entry_maker = function(pr)
          local decision = pr.reviewDecision or "REVIEW_REQUIRED"
          return {
            value = pr,
            display = string.format("#%d [%s] %s", pr.number, decision, pr.title),
            ordinal = pr.title,
          }
        end,
      }),
      sorter = modules.conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        local function open_pr_actions()
          local selection = modules.action_state.get_selected_entry()
          modules.actions.close(prompt_bufnr)
          if selection and selection.value then
            select_pr_action_picker(modules, selection.value)
          end
        end

        map("i", "<CR>", open_pr_actions)
        map("n", "<CR>", open_pr_actions)
        return true
      end,
    })
    :find()
end

function M.pull_requests()
  local modules = telescope_modules()
  if not modules then
    return
  end

  local query_results = pr_service.list_queries_with_results()

  modules.pickers
    .new({}, {
      prompt_title = "PR Queries",
      finder = modules.finders.new_table({
        results = query_results,
        entry_maker = function(result)
          local count = #(result.prs or {})
          local suffix = result.error and " [error]" or ""
          local label = string.format("%s/%s (%d)%s", result.query.folder, result.query.label, count, suffix)
          return {
            value = result,
            display = label,
            ordinal = label,
          }
        end,
      }),
      sorter = modules.conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        local function select_query()
          local selection = modules.action_state.get_selected_entry()
          modules.actions.close(prompt_bufnr)
          if not selection or not selection.value then
            return
          end

          if selection.value.error then
            vim.notify(selection.value.error, vim.log.levels.ERROR)
            return
          end

          select_pr_picker(modules, selection.value)
        end

        map("i", "<CR>", select_query)
        map("n", "<CR>", select_query)
        return true
      end,
    })
    :find()
end

return M
