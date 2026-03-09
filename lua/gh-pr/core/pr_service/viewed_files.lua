local M = {}
local review_context = require("gh-pr.core.review_context")

local VIEWED_FILES_QUERY = [[
query($owner:String!, $name:String!, $number:Int!, $first:Int!, $after:String) {
  repository(owner:$owner, name:$name) {
    pullRequest(number:$number) {
      id
      files(first:$first, after:$after) {
        nodes {
          path
          viewerViewedState
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
}
]]

local function normalize_path(path)
  return review_context.normalize_path(path)
end

local function viewed_files_variables(repository, number, first, after)
  local variables = {
    { flag = "-f", key = "owner", value = repository.owner },
    { flag = "-f", key = "name", value = repository.name },
    { flag = "-F", key = "number", value = tonumber(number) or number },
    { flag = "-F", key = "first", value = tonumber(first) or 100 },
  }

  if type(after) == "string" and after ~= "" then
    variables[#variables + 1] = { flag = "-f", key = "after", value = after }
  end

  return variables
end

local function parse_page(response)
  local data = type(response) == "table" and response.data or nil
  local repo_node = type(data) == "table" and data.repository or nil
  local pr_node = type(repo_node) == "table" and repo_node.pullRequest or nil
  if type(pr_node) ~= "table" then
    return nil, "Unable to resolve pull request for viewed files"
  end

  local pull_request_id = type(pr_node.id) == "string" and pr_node.id or ""
  if pull_request_id == "" then
    return nil, "Unable to resolve pull request GraphQL id for viewed files"
  end

  local files_connection = type(pr_node.files) == "table" and pr_node.files or {}
  local nodes = type(files_connection.nodes) == "table" and files_connection.nodes or {}
  local page_info = type(files_connection.pageInfo) == "table" and files_connection.pageInfo or {}

  local viewed = {}
  for _, node in ipairs(nodes) do
    local path = normalize_path(type(node) == "table" and node.path or "")
    if path ~= "" then
      viewed[path] = (type(node.viewerViewedState) == "string" and node.viewerViewedState:upper() or "") == "VIEWED"
    end
  end

  return {
    pull_request_id = pull_request_id,
    files = viewed,
    has_next_page = page_info.hasNextPage == true,
    end_cursor = type(page_info.endCursor) == "string" and page_info.endCursor or nil,
  }, nil
end

local function fetch_pull_request_graphql_id(repository, number, ctx)
  local page, err = ctx.run_graphql(VIEWED_FILES_QUERY, viewed_files_variables(repository, number, 1))
  if not page then
    return nil, err
  end

  local parsed, parse_err = parse_page(page)
  if not parsed then
    return nil, parse_err
  end

  return parsed.pull_request_id, nil
end

local function resolve_repository(ctx)
  local repository, repo_err = ctx.resolve_repository()
  if not repository then
    return nil, repo_err
  end
  return repository, nil
end

function M.fetch_viewed_files(number, opts, ctx)
  opts = type(opts) == "table" and opts or {}

  local repository, repo_err = resolve_repository(ctx)
  if not repository then
    return nil, repo_err
  end

  local first = ctx.clamp_positive(type(opts.page_size) == "number" and opts.page_size or 100, 100, 100)
  local after = nil
  local files = {}
  local pull_request_id = ""

  while true do
    local response, err = ctx.run_graphql(VIEWED_FILES_QUERY, viewed_files_variables(repository, number, first, after))
    if not response then
      return nil, err
    end

    local page, parse_err = parse_page(response)
    if not page then
      return nil, parse_err
    end

    pull_request_id = page.pull_request_id
    for path, viewed in pairs(page.files) do
      files[path] = viewed == true
    end

    if not page.has_next_page or not page.end_cursor then
      break
    end
    after = page.end_cursor
  end

  return {
    pull_request_id = pull_request_id,
    files = files,
  }, nil
end

function M.fetch_viewed_files_async(number, opts, callback, ctx)
  opts = type(opts) == "table" and opts or {}
  callback = callback or function() end

  local repository, repo_err = resolve_repository(ctx)
  if not repository then
    callback(nil, repo_err)
    return
  end

  local first = ctx.clamp_positive(type(opts.page_size) == "number" and opts.page_size or 100, 100, 100)
  local files = {}
  local pull_request_id = ""

  local function load_next(after)
    ctx.run_graphql_async(VIEWED_FILES_QUERY, viewed_files_variables(repository, number, first, after), function(response, err)
      if not response then
        callback(nil, err)
        return
      end

      local page, parse_err = parse_page(response)
      if not page then
        callback(nil, parse_err)
        return
      end

      pull_request_id = page.pull_request_id
      for path, viewed in pairs(page.files) do
        files[path] = viewed == true
      end

      if page.has_next_page and page.end_cursor then
        load_next(page.end_cursor)
        return
      end

      callback({
        pull_request_id = pull_request_id,
        files = files,
      }, nil)
    end)
  end

  load_next(nil)
end

local function mutate_file_viewed(pull_request_id, path, viewed, ctx)
  local mutation_name = viewed == true and "markFileAsViewed" or "unmarkFileAsViewed"
  local mutation = string.format([[
mutation($pullRequestId:ID!, $path:String!) {
  %s(input:{ pullRequestId:$pullRequestId, path:$path }) {
    pullRequest {
      id
    }
  }
}
]], mutation_name)

  local response, err = ctx.run_graphql(mutation, {
    { flag = "-f", key = "pullRequestId", value = pull_request_id },
    { flag = "-f", key = "path", value = path },
  })
  if not response then
    return false, err
  end

  local data = type(response) == "table" and response.data or nil
  local mutation_node = type(data) == "table" and data[mutation_name] or nil
  local pull_request = type(mutation_node) == "table" and mutation_node.pullRequest or nil
  if type(pull_request) ~= "table" or type(pull_request.id) ~= "string" or pull_request.id == "" then
    return false, "Unable to update GitHub viewed state"
  end

  return true, nil
end

local function dedupe_paths(paths)
  local normalized = {}
  local seen = {}

  for _, path in ipairs(type(paths) == "table" and paths or {}) do
    local canonical = normalize_path(path)
    if canonical ~= "" and not seen[canonical] then
      seen[canonical] = true
      normalized[#normalized + 1] = canonical
    end
  end

  return normalized
end

function M.set_files_viewed(number, paths, viewed, opts, ctx)
  opts = type(opts) == "table" and opts or {}
  local normalized_paths = dedupe_paths(paths)
  if vim.tbl_isempty(normalized_paths) then
    return nil, "No file paths provided for viewed state update"
  end

  local repository, repo_err = resolve_repository(ctx)
  if not repository then
    return nil, repo_err
  end

  local pull_request_id = type(opts.pull_request_id) == "string" and opts.pull_request_id or ""
  if pull_request_id == "" then
    local id, id_err = fetch_pull_request_graphql_id(repository, number, ctx)
    if not id then
      return nil, id_err
    end
    pull_request_id = id
  end

  local updated_paths = {}
  local failures = {}

  for _, path in ipairs(normalized_paths) do
    local ok, err = mutate_file_viewed(pull_request_id, path, viewed == true, ctx)
    if ok then
      updated_paths[#updated_paths + 1] = path
    else
      failures[#failures + 1] = {
        path = path,
        error = err or "Unable to update viewed state",
      }
    end
  end

  return {
    pull_request_id = pull_request_id,
    total = #normalized_paths,
    updated_paths = updated_paths,
    failures = failures,
  }, nil
end

return M
