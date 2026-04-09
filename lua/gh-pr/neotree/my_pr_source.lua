local pr_service = require("gh-pr.pr_service")
local repo = require("gh-pr.repo")
local runtime_state = require("gh-pr.state")

local create = require("gh-pr.neotree.review_source")._create

return create({
  source_name = "gh_my_pr",
  display_name = "GH My PR",
  cache_key = "gh_my_pr",
  state_repo_key_field = "gh_my_pr_repo_key",
  id_prefix = "ghpr-my-pr",
  source_label = "My PR",
  loading_message = "Loading My PR...",
  stale_message = "Showing cached My PR while refreshing...",
  no_target_message = "No pull request matches the current branch in this repository.",
  not_git_message = "Open a git repository to use My PR",
  sync_runtime = function(_, details)
    runtime_state.set_active_pr(details, details)
  end,
  resolve_target_async = function(repo_context, session, callback)
    callback = type(callback) == "function" and callback or function() end
    local cwd = type(repo_context) == "table" and repo_context.git_root or nil
    repo.current_branch_async({ cwd = cwd }, function(branch, branch_err)
      branch = type(branch) == "string" and vim.trim(branch) or ""
      if branch == "" then
        session.branch_name = nil
        session.target_reason = branch_err or "My PR is unavailable on detached HEAD or without a local branch."
        callback(nil, nil)
        return
      end

      session.branch_name = branch
      pr_service.find_pr_for_branch_async(branch, {
        repository = type(repo_context) == "table" and repo_context.repository or nil,
      }, function(pr, err)
        if not pr then
          session.target_reason = err or ("No pull request matches branch `" .. branch .. "` in this repository.")
          callback(nil, nil)
          return
        end

        session.target_reason = nil
        callback({
          pr = pr,
          branch = branch,
        }, nil)
      end)
    end)
  end,
})
